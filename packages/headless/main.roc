## Chromium's headless shell, driven from Roc: started with a profile of its own (`Chrome`), and its
## tabs (`Tab`) used as a test or a renderer uses a page, over the DevTools protocol on the CLI
## platform's WebSocket. It names the CLI platform (cli/), so a program on it names this package:
## rocx itself (`rocx render`), and tests written in Roc. The browser is `$CHROME`, or the headless
## shell Playwright keeps in its cache; nothing of Playwright's runs.
package [Chrome, Tab] { crypto: "../crypto/main.roc", pf: platform "../../cli/platform/main.roc", tools: "../tools/main.roc" }
