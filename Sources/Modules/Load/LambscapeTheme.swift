import WebKit

/// Тема lambscape под нативные модули Utilitumus: нейтральные серые macOS,
/// системный акцент, светлая/тёмная вслед за системой. lambscape красит всё
/// через CSS-переменные на `[data-theme=…]` (специфичность 0,1,0) — здесь
/// `html[data-theme]` (0,1,1) перебивает любую выбранную в нём тему.
/// Свой выбор темы и логотип lambscape внутри приложения скрыты: заголовок и
/// тема — у окна.
enum LambscapeTheme {
    static let css = """
    /* Фон страницы прозрачный — просвечивает фон окна macOS (он подмешивает
       оттенок обоев, одним цветом его не повторить). Карточки — лёгкая
       подложка поверх, как строки нативных Form. Всё, что всплывает или
       прилипает поверх прокрутки, — сплошное (--solid) или с размытием. */
    html[data-theme] {
      color-scheme: dark;
      --bg: #262626; --solid: #323232;
      --deep: rgb(255 255 255 / .03); --panel: rgb(255 255 255 / .043); --raise: rgb(255 255 255 / .08);
      --border: rgb(255 255 255 / .1);
      --text: #dddddd; --strong: #ffffff; --muted: #a3a3a3; --faint: #7a7a7a;
      --accent: -apple-system-control-accent; --accent-ink: #ffffff;
      --red: #ff453a; --green: #30d158; --yellow: #ffd60a; --orange: #ff9f0a; --purple: #bf5af2; --cyan: #64d2ff; --blue: #0a84ff;
      --ok: var(--green); --warn: var(--orange); --bad: var(--red); --bad-ink: #ff6961; --bad-solid: #ff453a; --solid-ink: #1c1c1c;
      --ok-ink: var(--ok); --warn-ink: var(--warn); --on-warn: #1c1c1c;
      --chip: color-mix(in srgb, var(--accent) 22%, transparent); --chip-text: color-mix(in srgb, var(--accent) 55%, #ffffff);
      --s1: #0a84ff; --s2: #ff9f0a; --s3: #30d158; --s4: #ffd60a; --s5: #ff375f; --s6: #bf5af2; --s0: var(--faint);
      --s7: #64d2ff; --s8: #ff6961;
      --grid: rgb(255 255 255 / .08);
      --rad: 10px;
    }
    @media (prefers-color-scheme: light) {
      html[data-theme] {
        color-scheme: light;
        --bg: #f2f2f2; --solid: #ffffff;
        --deep: rgb(0 0 0 / .035); --panel: rgb(255 255 255 / .85); --raise: rgb(0 0 0 / .05);
        --border: rgb(0 0 0 / .1);
        --text: #262626; --strong: #000000; --muted: #5f5f5f; --faint: #a3a3a3;
        --accent-ink: #ffffff;
        --red: #ff3b30; --green: #28cd41; --yellow: #ffcc00; --orange: #ff9500; --purple: #af52de; --cyan: #32ade6; --blue: #007aff;
        --ok: #28cd41; --warn: #ff9500; --bad: #ff3b30; --bad-ink: #d70015; --bad-solid: #d70015; --solid-ink: #ffffff;
        --ok-ink: #248a3d; --warn-ink: #a05a00; --on-warn: #000000;
        --chip: color-mix(in srgb, var(--accent) 14%, transparent); --chip-text: color-mix(in srgb, var(--accent) 80%, #000000);
        --s1: #007aff; --s2: #ff9500; --s3: #28cd41; --s4: #e6b800; --s5: #ff2d55; --s6: #af52de; --s0: #b4b4b4;
        --s7: #32ade6; --s8: #ff3b30;
        --grid: rgb(0 0 0 / .07);
      }
    }
    html[data-theme] body { background: transparent; }
    html[data-theme] .card { border-color: transparent; }
    /* Шапка и подвал стоят на месте, прокручивается только содержимое между
       ними — под шапку ничего не заезжает. */
    html[data-theme] body { height: 100vh; min-height: 0; overflow: hidden; }
    html[data-theme] .top, html[data-theme] .foot { position: static; flex: none; background: transparent; }
    html[data-theme] main { flex: 1 1 auto; min-height: 0; overflow-y: auto; max-width: none; }
    /* Шапка в одну строку на любой ширине: индикаторы · время · обновить · вид.
       У lambscape до 900 px индикаторы и вид уходят во вторую строку. */
    html[data-theme] .bar {
      grid-template-columns: minmax(0, 1fr) auto auto auto; grid-template-areas: "meta when refresh view";
      padding: 6px 12px 5px;
    }
    html[data-theme] .row2 { display: contents; }
    html[data-theme] .meta { flex-wrap: nowrap; overflow: hidden; }
    html[data-theme] .meta .lbl, html[data-theme] #refresh-btn .t { display: none; }
    html[data-theme] .when { flex-direction: row; }
    html[data-theme] .tabs { padding-top: 0; }
    /* Всплывает поверх содержимого — нужен сплошной фон. */
    html[data-theme] .mtip, html[data-theme] .tip, html[data-theme] dialog.confirm,
    html[data-theme] .bulk, html[data-theme] .toast.quiet, html[data-theme] .procs.all .more {
      background: var(--solid);
    }
    .top .brand, #theme-btn, #theme-pop { display: none !important; }
    """

    /// До первой отрисовки, чтобы страница не мигала своей темой.
    /// Через CSSOM, а не `<style>`: CSP lambscape (`default-src 'self'`)
    /// встроенные стили блокирует, а конструируемые таблицы — нет.
    static var userScript: WKUserScript {
        let js = """
        (() => {
          const sheet = new CSSStyleSheet();
          sheet.replaceSync(\(jsonString(css)));
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
          // Прокрутка теперь у <main>, а lambscape при смене вкладки сбрасывает окно.
          addEventListener('hashchange', () => { const m = document.querySelector('main'); if (m) m.scrollTop = 0; });
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    private static func jsonString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let array = String(data: data, encoding: .utf8)!
        return String(array.dropFirst().dropLast())
    }
}
