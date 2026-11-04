// utilitumus-voice — процесс-помощник распознавания речи (sherpa-onnx, статическая линковка).
//
// Отдельный процесс, а не dylib в приложении: под hardened runtime без
// disable-library-validation чужая библиотека не загрузится, а ослаблять защиту всего
// приложения ради модуля незачем. Помощник подписан отдельно, без entitlements.
//
// Протокол через stdin/stdout, строгий и бинарный:
//   запрос  — одна строка JSON с '\n' в конце (плоский объект, до 4096 байт);
//   ответ   — одна строка JSON с '\n'.
//
//   {"cmd":"load","dir":"/abs/path","kind":"transducer"}  -> {"ok":true} | {"ok":false,"error":"..."}
//   {"cmd":"transcribe","samples":N,"rate":16000}         -> сразу после строки ровно N float32 LE (моно),
//                                                            ответ {"ok":true,"text":"...","ms":T}
//   {"cmd":"quit"}                                        -> без ответа, процесс выходит.
//
// Всё остальное — ошибка. N ограничено (1...16000*600). Закрытый stdin — выход.
// Помощник не пишет на диск и не ходит в сеть: после старта на процесс накладывается
// песочница (deny network*, deny file-write*) — на случай ошибки в разборе модели.

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "sherpa-onnx/c-api/c-api.h"

// sandbox_init объявлен в <sandbox.h> как deprecated, но работает; объявляем сами,
// чтобы не ловить предупреждения.
extern int sandbox_init(const char *profile, uint64_t flags, char **errorbuf);
extern void sandbox_free_error(char *errorbuf);

#define MAX_LINE 4096
#define MAX_SAMPLES (16000L * 600L)  // 10 минут
#define NUM_THREADS 4

_Static_assert(sizeof(float) == 4, "float32");
#if !defined(__LITTLE_ENDIAN__) && !(defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__)
#error "протокол ожидает little-endian"
#endif

static const SherpaOnnxOfflineRecognizer *g_rec = NULL;

static double now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

// ---------- Вывод ----------

static void out_json_string(const char *s) {
  putchar('"');
  for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
    switch (*p) {
      case '"': fputs("\\\"", stdout); break;
      case '\\': fputs("\\\\", stdout); break;
      case '\n': fputs("\\n", stdout); break;
      case '\r': fputs("\\r", stdout); break;
      case '\t': fputs("\\t", stdout); break;
      default:
        if (*p < 0x20) printf("\\u%04x", *p);
        else putchar(*p);
    }
  }
  putchar('"');
}

static void reply_ok(void) {
  fputs("{\"ok\":true}\n", stdout);
  fflush(stdout);
}

static void reply_error(const char *msg) {
  fputs("{\"ok\":false,\"error\":", stdout);
  out_json_string(msg);
  fputs("}\n", stdout);
  fflush(stdout);
}

// ---------- Разбор запроса: плоский JSON-объект со строками и числами ----------

typedef struct {
  char key[32];
  char str[1024];  // значение-строка (UTF-8)
  double num;      // значение-число
  int is_str;
} Field;

#define MAX_FIELDS 8

static int hex4(const char *p, unsigned *out) {
  unsigned v = 0;
  for (int i = 0; i < 4; i++) {
    char c = p[i];
    v <<= 4;
    if (c >= '0' && c <= '9') v |= (unsigned)(c - '0');
    else if (c >= 'a' && c <= 'f') v |= (unsigned)(c - 'a' + 10);
    else if (c >= 'A' && c <= 'F') v |= (unsigned)(c - 'A' + 10);
    else return 0;
  }
  *out = v;
  return 1;
}

static size_t put_utf8(char *d, unsigned cp) {
  if (cp < 0x80) { d[0] = (char)cp; return 1; }
  if (cp < 0x800) { d[0] = (char)(0xC0 | (cp >> 6)); d[1] = (char)(0x80 | (cp & 0x3F)); return 2; }
  if (cp < 0x10000) {
    d[0] = (char)(0xE0 | (cp >> 12)); d[1] = (char)(0x80 | ((cp >> 6) & 0x3F)); d[2] = (char)(0x80 | (cp & 0x3F));
    return 3;
  }
  d[0] = (char)(0xF0 | (cp >> 18)); d[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
  d[2] = (char)(0x80 | ((cp >> 6) & 0x3F)); d[3] = (char)(0x80 | (cp & 0x3F));
  return 4;
}

// Разбирает строку JSON, p указывает на открывающую кавычку. Возвращает указатель после
// закрывающей или NULL.
static const char *parse_string(const char *p, char *dst, size_t cap) {
  if (*p != '"') return NULL;
  p++;
  size_t n = 0;
  while (*p && *p != '"') {
    if (n + 5 > cap) return NULL;  // запас под самый длинный символ + NUL
    if (*p == '\\') {
      p++;
      switch (*p) {
        case '"': dst[n++] = '"'; break;
        case '\\': dst[n++] = '\\'; break;
        case '/': dst[n++] = '/'; break;
        case 'n': dst[n++] = '\n'; break;
        case 'r': dst[n++] = '\r'; break;
        case 't': dst[n++] = '\t'; break;
        case 'b': dst[n++] = '\b'; break;
        case 'f': dst[n++] = '\f'; break;
        case 'u': {
          unsigned cp;
          if (!hex4(p + 1, &cp)) return NULL;
          p += 4;
          if (cp >= 0xD800 && cp <= 0xDBFF) {  // суррогатная пара
            unsigned lo;
            if (p[1] != '\\' || p[2] != 'u' || !hex4(p + 3, &lo) || lo < 0xDC00 || lo > 0xDFFF) return NULL;
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            p += 6;
          } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
            return NULL;
          }
          if (cp == 0) return NULL;
          n += put_utf8(dst + n, cp);
          break;
        }
        default: return NULL;
      }
      p++;
    } else {
      if ((unsigned char)*p < 0x20) return NULL;
      dst[n++] = *p++;
    }
  }
  if (*p != '"') return NULL;
  dst[n] = 0;
  return p + 1;
}

static const char *skip_ws(const char *p) {
  while (*p == ' ' || *p == '\t') p++;
  return p;
}

// Возвращает число полей или -1 при любой неточности.
static int parse_object(const char *line, Field *fields) {
  const char *p = skip_ws(line);
  if (*p != '{') return -1;
  p = skip_ws(p + 1);
  int n = 0;
  if (*p == '}') return (*skip_ws(p + 1) == 0) ? 0 : -1;
  for (;;) {
    if (n >= MAX_FIELDS) return -1;
    Field *f = &fields[n];
    memset(f, 0, sizeof *f);
    p = parse_string(skip_ws(p), f->key, sizeof f->key);
    if (!p) return -1;
    p = skip_ws(p);
    if (*p != ':') return -1;
    p = skip_ws(p + 1);
    if (*p == '"') {
      p = parse_string(p, f->str, sizeof f->str);
      if (!p) return -1;
      f->is_str = 1;
    } else {
      char *end;
      f->num = strtod(p, &end);
      if (end == p || !isfinite(f->num)) return -1;
      p = end;
    }
    n++;
    p = skip_ws(p);
    if (*p == ',') { p++; continue; }
    if (*p == '}') return (*skip_ws(p + 1) == 0) ? n : -1;
    return -1;
  }
}

static const Field *find(const Field *fields, int n, const char *key) {
  for (int i = 0; i < n; i++)
    if (strcmp(fields[i].key, key) == 0) return &fields[i];
  return NULL;
}

// ---------- Модель ----------

static int file_exists(const char *path) {
  struct stat st;
  return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

// base.int8.onnx, если есть, иначе base.onnx.
static int pick_model(const char *dir, const char *base, char *out, size_t cap) {
  snprintf(out, cap, "%s/%s.int8.onnx", dir, base);
  if (file_exists(out)) return 1;
  snprintf(out, cap, "%s/%s.onnx", dir, base);
  return file_exists(out);
}

static void do_load(const Field *fields, int n) {
  const Field *dir = find(fields, n, "dir"), *kind = find(fields, n, "kind");
  if (!dir || !dir->is_str || !kind || !kind->is_str) { reply_error("load: нужны dir и kind"); return; }
  if (strcmp(kind->str, "transducer") != 0) { reply_error("load: поддерживается только kind=transducer"); return; }
  if (dir->str[0] != '/') { reply_error("load: dir должен быть абсолютным путём"); return; }

  char enc[1100], dec[1100], joi[1100], tok[1100];
  snprintf(tok, sizeof tok, "%s/tokens.txt", dir->str);
  if (!pick_model(dir->str, "encoder", enc, sizeof enc) || !pick_model(dir->str, "decoder", dec, sizeof dec) ||
      !pick_model(dir->str, "joiner", joi, sizeof joi) || !file_exists(tok)) {
    reply_error("load: в папке нет файлов модели (encoder/decoder/joiner/tokens)");
    return;
  }

  if (g_rec) { SherpaOnnxDestroyOfflineRecognizer(g_rec); g_rec = NULL; }

  SherpaOnnxOfflineRecognizerConfig c;
  memset(&c, 0, sizeof c);
  c.feat_config.sample_rate = 16000;
  c.feat_config.feature_dim = 80;
  c.model_config.tokens = tok;
  c.model_config.num_threads = NUM_THREADS;
  c.model_config.provider = "cpu";
  c.model_config.debug = 0;
  c.model_config.transducer.encoder = enc;
  c.model_config.transducer.decoder = dec;
  c.model_config.transducer.joiner = joi;
  c.model_config.model_type = "nemo_transducer";
  c.decoding_method = "greedy_search";

  g_rec = SherpaOnnxCreateOfflineRecognizer(&c);
  if (!g_rec) { reply_error("load: не удалось создать распознаватель (модель повреждена?)"); return; }
  reply_ok();
}

// ---------- Распознавание ----------

// Читает ровно count байт; false — stdin закрылся раньше.
static int read_exact(void *buf, size_t count) {
  return fread(buf, 1, count, stdin) == count;
}

// Возвращает 0, если нужно завершить процесс (поток сломан).
static int do_transcribe(const Field *fields, int n) {
  const Field *ns = find(fields, n, "samples"), *rate = find(fields, n, "rate");
  if (!ns || ns->is_str || !rate || rate->is_str || ns->num != floor(ns->num) || rate->num != floor(rate->num)) {
    reply_error("transcribe: нужны целые samples и rate");
    return 0;  // сколько байт идёт следом — неизвестно, поток не восстановить
  }
  if (ns->num < 1 || ns->num > (double)MAX_SAMPLES) {
    reply_error("transcribe: samples вне диапазона 1...9600000");
    return 0;
  }
  size_t count = (size_t)ns->num;
  float *samples = malloc(count * sizeof(float));
  if (!samples) { reply_error("transcribe: не хватило памяти"); return 0; }
  if (!read_exact(samples, count * sizeof(float))) { free(samples); return 0; }

  if (rate->num < 8000 || rate->num > 48000) { free(samples); reply_error("transcribe: rate вне диапазона 8000...48000"); return 1; }
  if (!g_rec) { free(samples); reply_error("transcribe: модель не загружена"); return 1; }

  double t0 = now_ms();
  const SherpaOnnxOfflineStream *s = SherpaOnnxCreateOfflineStream(g_rec);
  SherpaOnnxAcceptWaveformOffline(s, (int32_t)rate->num, samples, (int32_t)count);
  free(samples);
  SherpaOnnxDecodeOfflineStream(g_rec, s);
  const SherpaOnnxOfflineRecognizerResult *r = SherpaOnnxGetOfflineStreamResult(s);
  double ms = now_ms() - t0;

  fputs("{\"ok\":true,\"text\":", stdout);
  out_json_string(r && r->text ? r->text : "");
  printf(",\"ms\":%d}\n", (int)ms);
  fflush(stdout);
  if (r) SherpaOnnxDestroyOfflineRecognizerResult(r);
  SherpaOnnxDestroyOfflineStream(s);
  return 1;
}

// ---------- main ----------

// Читает строку запроса без '\n'. 1 — есть строка, 0 — EOF, -1 — слишком длинная.
static int read_line(char *buf) {
  size_t n = 0;
  int c;
  while ((c = getchar()) != EOF) {
    if (c == '\n') { buf[n] = 0; return 1; }
    if (n >= MAX_LINE) return -1;
    buf[n++] = (char)c;
  }
  return 0;
}

int main(void) {
  setvbuf(stdout, NULL, _IOFBF, 1 << 16);

  // Песочница: ни сети, ни записи на диск. Чтение остаётся (модель, системные
  // библиотеки). Уже открытые дескрипторы (stdin/stdout/stderr) работают как раньше.
  char *err = NULL;
  if (sandbox_init("(version 1)(allow default)(deny network*)(deny file-write*)", 0, &err) != 0) {
    reply_error(err ? err : "sandbox_init");
    return 1;
  }

  static char line[MAX_LINE + 1];
  static Field fields[MAX_FIELDS];
  for (;;) {
    int r = read_line(line);
    if (r == 0) break;
    if (r < 0) { reply_error("строка запроса длиннее 4096 байт"); return 1; }

    int n = parse_object(line, fields);
    const Field *cmd = n > 0 ? find(fields, n, "cmd") : NULL;
    if (!cmd || !cmd->is_str) { reply_error("не разобран запрос"); continue; }

    if (strcmp(cmd->str, "quit") == 0) break;
    else if (strcmp(cmd->str, "load") == 0) do_load(fields, n);
    else if (strcmp(cmd->str, "transcribe") == 0) { if (!do_transcribe(fields, n)) break; }
    else reply_error("неизвестная команда");
  }

  if (g_rec) SherpaOnnxDestroyOfflineRecognizer(g_rec);
  return 0;
}
