import type { Metadata } from "next";
import Link from "next/link";
import { Callout } from "@/components/callout";
import { CodeBlock } from "@/components/code-block";
import { DocsSection, DocsSubsection, InlineCode } from "@/components/docs-shell";
import { Pager } from "@/components/pager";
import { RevealController } from "@/components/landing/reveal-controller";

export const metadata: Metadata = {
  title: "Mini Router with Pi and Cockpit",
  description:
    "Connect Pi and Cockpit to Open Mini Router, then pair Remote Pi and run the project as a daemon.",
};

const MODELS_JSON = [
  "{",
  '  "providers": {',
  '    "mini-router": {',
  '      "baseUrl": "http://127.0.0.1:5088/v1",',
  '      "api": "openai-completions",',
  '      "apiKey": "$MINI_ROUTER_API_KEY",',
  '      "authHeader": true,',
  '      "compat": {',
  '        "supportsDeveloperRole": false,',
  '        "supportsReasoningEffort": false,',
  '        "supportsUsageInStreaming": true',
  "      },",
  '      "models": [',
  '        { "id": "auto/code", "name": "Mini Router - Code", "reasoning": false, "input": ["text"], "contextWindow": 32768, "maxTokens": 8192 },',
  '        { "id": "auto/fast", "name": "Mini Router - Fast", "reasoning": false, "input": ["text"], "contextWindow": 32768, "maxTokens": 8192 },',
  '        { "id": "auto/cheap", "name": "Mini Router - Cheap", "reasoning": false, "input": ["text"], "contextWindow": 32768, "maxTokens": 8192 }',
  "      ]",
  "    }",
  "  }",
  "}",
].join("\n");

export default function MiniRouterTutorial() {
  return (
    <div className="page">
      <div className="page-body">
        <div className="wrap">
          <div className="tut">
            <header className="page-head reveal" style={{ maxWidth: "none" }}>
              <span className="eyebrow">Tutorial · Integration</span>
              <h1>Mini Router with Pi and Cockpit</h1>
              <p className="lede">
                Point Pi at an OpenAI-compatible Mini Router, select a routed
                coding model in Cockpit, pair Remote Pi, and optionally keep the
                project alive as a background daemon.
              </p>
            </header>

            <article className="prose">
              <DocsSection id="architecture" title="How the pieces fit">
                <CodeBlock
                  code={["Cockpit", "  → Pi (interactive or RPC)", "  → Mini Router /v1/chat/completions", "  → auto/code, auto/fast, or auto/cheap", "", "Remote Pi app", "  → relay", "  → Remote Pi plugin inside Pi"].join("\n")}
                  label="Request path"
                  language="text"
                />
                <p>
                  Cockpit controls Pi, and Pi calls Mini Router directly. The
                  relay carries paired-device commands and mesh messages; it is
                  not an LLM proxy.
                </p>
              </DocsSection>

              <DocsSection id="prereqs" title="Before you start">
                <ul className="ml-6 list-disc space-y-2">
                  <li>Node 20+, npm, and Pi on the Cockpit machine.</li>
                  <li>A reachable Mini Router URL and an active <InlineCode>sk-omr-...</InlineCode> key.</li>
                  <li><Link className="text-accent underline" href="/download">Cockpit installed</Link> on Windows, macOS, or Linux.</li>
                  <li>The Remote Pi mobile app if you want phone access.</li>
                </ul>
                <p>
                  This guide uses <InlineCode>http://127.0.0.1:5088/v1</InlineCode>.
                  For production, use your HTTPS URL and keep the <InlineCode>/v1</InlineCode> suffix.
                </p>
              </DocsSection>

              <DocsSection id="install" title="1. Install Remote Pi">
                <CodeBlock code={["pi install npm:remote-pi", "npm install -g remote-pi"].join("\n")} label="PowerShell or bash" language="bash" />
                <p>
                  The first command adds the Pi plugin; the second exposes the
                  shell CLI. On a fresh macOS or Linux machine, you can instead run:
                </p>
                <CodeBlock code="curl -fsSL https://remote-pi.jacobmoura.work/install.sh | bash" label="macOS or Linux" language="bash" />
                <Callout variant="note" title="Background daemons">
                  On macOS or Linux, run <InlineCode>/remote-pi install</InlineCode> once
                  inside Pi to install the supervisor before creating daemons.
                </Callout>
              </DocsSection>

              <DocsSection id="provider" title="2. Add Mini Router to Pi">
                <p>
                  Create <InlineCode>~/.pi/agent/models.json</InlineCode>. On Windows,
                  use <InlineCode>%USERPROFILE%\.pi\agent\models.json</InlineCode>.
                  Merge this provider if the file already exists.
                </p>
                <CodeBlock code={MODELS_JSON} label="models.json" language="json" />
                <p>
                  <InlineCode>openai-completions</InlineCode> targets{" "}
                  <InlineCode>POST /v1/chat/completions</InlineCode>. Models are
                  explicit because Pi does not build a custom registry from{" "}
                  <InlineCode>GET /v1/models</InlineCode>.
                </p>
              </DocsSection>

              <DocsSection id="key" title="3. Provide the API key">
                <DocsSubsection title="Windows PowerShell">
                  <CodeBlock
                    code={['$env:MINI_ROUTER_API_KEY="sk-omr-replace-with-your-key"', 'setx MINI_ROUTER_API_KEY "sk-omr-replace-with-your-key"'].join("\n")}
                    label="Current shell, then future processes"
                    language="powershell"
                  />
                  <p><InlineCode>setx</InlineCode> affects new processes only. Fully quit and reopen Cockpit.</p>
                </DocsSubsection>
                <DocsSubsection title="macOS and Linux">
                  <CodeBlock code="export MINI_ROUTER_API_KEY='sk-omr-replace-with-your-key'" label="bash" language="bash" />
                  <p>A GUI-launched Cockpit may not inherit shell startup files. Configure the desktop environment or launch it from this terminal.</p>
                </DocsSubsection>
                <Callout variant="warning" title="Do not store the key in Git">
                  Keep <InlineCode>$MINI_ROUTER_API_KEY</InlineCode> in the JSON.
                  Pi can also use auth.json or a secret-manager command.
                </Callout>
              </DocsSection>

              <DocsSection id="verify" title="4. Verify Pi and select the model">
                <CodeBlock code={["pi --list-models mini-router", "pi --provider mini-router --model auto/code"].join("\n")} label="PowerShell or bash" language="bash" />
                <p>
                  The list should include <InlineCode>mini-router/auto/code</InlineCode>,
                  <InlineCode> mini-router/auto/fast</InlineCode>, and
                  <InlineCode> mini-router/auto/cheap</InlineCode>. In an existing
                  session, use <InlineCode>/model</InlineCode>.
                </p>
              </DocsSection>

              <DocsSection id="remote" title="5. Configure Remote Pi from the CLI">
                <CodeBlock code={["remote-pi setup", "remote-pi status", "remote-pi peers", "remote-pi pair", "remote-pi devices"].join("\n")} label="PowerShell or bash" language="bash" />
                <p>
                  Use the community relay for the zero-configuration path and
                  scan the pairing QR with the mobile app. The same commands work
                  as Pi slash commands, such as <InlineCode>/remote-pi status</InlineCode>.
                </p>
                <p>See the <Link className="text-accent underline" href="/docs">Remote Pi reference</Link> for relay overrides, revocation, and security.</p>
              </DocsSection>

              <DocsSection id="daemon" title="6. Keep the project running as a daemon">
                <CodeBlock
                  code={["remote-pi create /path/to/Open.Mini.Router --name mini-router", "remote-pi daemons", "remote-pi daemon start", "remote-pi daemon status", 'remote-pi daemon send <id> "Review the project without changing files."'].join("\n")}
                  label="macOS or Linux"
                  language="bash"
                />
                <p>Use the real daemon id without angle brackets. Continue with the <Link className="text-accent underline" href="/tutorials/daemon">daemon tutorial</Link> for lifecycle, logs, and recovery.</p>
              </DocsSection>

              <DocsSection id="cockpit" title="7. Open the project in Cockpit">
                <ol className="ml-6 list-decimal space-y-2">
                  <li>Restart Cockpit after making the API key available.</li>
                  <li>Add the Mini Router repository as a workspace.</li>
                  <li>Start <InlineCode>pi --provider mini-router --model auto/code</InlineCode> in a workspace terminal.</li>
                  <li>Confirm the picker shows <InlineCode>mini-router/auto/code</InlineCode>.</li>
                </ol>
                <p>Cockpit&apos;s local CLI controls tabs and tasks; it does not configure Pi providers or the relay.</p>
                <CodeBlock
                  code={["cockpit list-tabs", "cockpit new-tab --cwd . --title mini-router-agent", 'cockpit send --tab-id <tab-id> --enter "pi --provider mini-router --model auto/code"', "cockpit read-tab <tab-id>"].join("\n")}
                  label="Inside a Cockpit terminal"
                  language="bash"
                />
                <p>For layouts, Task Run, targets, themes, databases, and every command, use the <Link className="text-accent underline" href="/cockpit/docs">Cockpit reference</Link>.</p>
              </DocsSection>

              <DocsSection id="troubleshooting" title="Troubleshooting">
                <DocsSubsection title="Models do not appear">
                  <p>Check models.json and Pi&apos;s environment, rerun <InlineCode>pi --list-models mini-router</InlineCode>, then restart the RPC session.</p>
                </DocsSubsection>
                <DocsSubsection title="Mini Router returns 401 or 404">
                  <p>Use a Mini Router key, keep <InlineCode>authHeader: true</InlineCode>, and restart Cockpit after environment changes. The base URL ends in <InlineCode>/v1</InlineCode>, not <InlineCode>/v1/chat/completions</InlineCode>.</p>
                </DocsSubsection>
                <DocsSubsection title="Relay or daemon is offline">
                  <CodeBlock code={["remote-pi status", "remote-pi peers", "remote-pi daemons", "remote-pi daemon status"].join("\n")} label="Diagnostics" language="bash" />
                </DocsSubsection>
                <DocsSubsection title="Cockpit cannot find pi or remote-pi">
                  <CodeBlock code={["# PowerShell", "Get-Command pi", "Get-Command remote-pi", "", "# bash", "command -v pi", "command -v remote-pi"].join("\n")} label="Check PATH" language="bash" />
                </DocsSubsection>
              </DocsSection>

              <DocsSection id="security" title="Security notes">
                <ul className="ml-6 list-disc space-y-2">
                  <li>Use HTTPS for non-local Mini Router endpoints.</li>
                  <li>Never commit API keys, auth.json, or secret files.</li>
                  <li>The community relay operator remains inside the documented trust boundary.</li>
                  <li>For sensitive work, <Link className="text-accent underline" href="/docs#self-host">self-host the relay</Link> behind a VPN.</li>
                </ul>
              </DocsSection>
            </article>

            <Pager prev={{ href: "/tutorials", label: "All tutorials" }} />
          </div>
        </div>
      </div>
      <RevealController />
    </div>
  );
}
