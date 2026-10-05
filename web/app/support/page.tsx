'use client';

import React, { useState } from 'react';
import Link from 'next/link';

type TabKey = 'macos' | 'linux' | 'windows' | 'keys' | 'troubleshooting';

export default function SupportPage() {
  const [activeTab, setActiveTab] = useState<TabKey>('macos');
  const [copiedIndex, setCopiedIndex] = useState<string | null>(null);

  const copyToClipboard = (text: string, id: string) => {
    navigator.clipboard.writeText(text);
    setCopiedIndex(id);
    setTimeout(() => setCopiedIndex(null), 2000);
  };

  return (
    <div className="support-wrapper">
      {/* Header */}
      <header className="support-header">
        <Link href="/" className="brand-link">
          <img src="/assets/logo.png" alt="" width={36} height={36} className="logo" />
          <span className="brand-name">Herdcats</span>
        </Link>
      </header>

      {/* Main Content */}
      <main className="support-main">
        {/* Hero Section */}
        <section className="hero-section">
          <h1 className="hero-title">Support</h1>
          <p className="hero-subtitle">
            SSH setup &amp; configuration guide. Herdcats connects directly from your iPhone to your remote machine over SSH to orchestrate
            Herdr workspaces, Git worktrees, and autonomous coding agents.
          </p>
          <div className="security-banner">
            <span className="shield-icon">🔒</span>
            <div className="security-text">
              <strong>Direct &amp; Secure:</strong> No intermediate relays, proxies, or cloud daemons.
              Credentials stay encrypted in your iPhone’s on-device Keychain.
              <span className="ts-tag">Tailscale Recommended</span>
            </div>
          </div>
        </section>

        {/* Tab Navigation */}
        <div className="tabs-bar">
          <button
            type="button"
            className={`tab-btn ${activeTab === 'macos' ? 'active' : ''}`}
            onClick={() => setActiveTab('macos')}
          >
             macOS
          </button>
          <button
            type="button"
            className={`tab-btn ${activeTab === 'linux' ? 'active' : ''}`}
            onClick={() => setActiveTab('linux')}
          >
            🐧 Linux
          </button>
          <button
            type="button"
            className={`tab-btn ${activeTab === 'windows' ? 'active' : ''}`}
            onClick={() => setActiveTab('windows')}
          >
            🪟 Windows / WSL
          </button>
          <button
            type="button"
            className={`tab-btn ${activeTab === 'keys' ? 'active' : ''}`}
            onClick={() => setActiveTab('keys')}
          >
            🔑 SSH Keys
          </button>
          <button
            type="button"
            className={`tab-btn ${activeTab === 'troubleshooting' ? 'active' : ''}`}
            onClick={() => setActiveTab('troubleshooting')}
          >
            🛠 Troubleshooting
          </button>
        </div>

        {/* TAB 1: macOS */}
        {activeTab === 'macos' && (
          <div className="tab-pane">
            <div className="guide-card">
              <h2>Setting up SSH on macOS</h2>
              <p className="card-desc">
                Follow these steps to enable SSH access on your Mac and generate an ed25519 key for Herdcats.
              </p>
              <p className="prereq-text">
                Before you start: install <a href="https://herdr.dev" target="_blank" rel="noopener noreferrer">Herdr</a> on
                the Mac and keep a Herdr session running. Herdcats drives the <code>herdr</code> CLI over SSH.
              </p>

              <ol className="step-list">
                <li className="step-item">
                  <div className="step-num">1</div>
                  <div className="step-body">
                    <h3>Enable Remote Login</h3>
                    <p>Open <strong>System Settings</strong> on your Mac:</p>
                    <p className="path-text">Apple Menu () → System Settings → General → Sharing → turn on <strong>Remote Login</strong>.</p>
                    <p className="tip-text">Ensure your user account is permitted under &ldquo;Allow access for&rdquo;.</p>
                  </div>
                </li>

                <li className="step-item">
                  <div className="step-num">2</div>
                  <div className="step-body">
                    <h3>Generate an Ed25519 Key &amp; Authorize It</h3>
                    <p>Open Terminal on your Mac and run this one-line command:</p>
                    <div className="code-box">
                      <pre><code>ssh-keygen -t ed25519 -N &quot;&quot; -f ~/.ssh/herdcats_key &amp;&amp; cat ~/.ssh/herdcats_key.pub &gt;&gt; ~/.ssh/authorized_keys &amp;&amp; chmod 700 ~/.ssh &amp;&amp; chmod 600 ~/.ssh/authorized_keys</code></pre>
                      <button
                        type="button"
                        className="copy-btn"
                        onClick={() => copyToClipboard('ssh-keygen -t ed25519 -N "" -f ~/.ssh/herdcats_key && cat ~/.ssh/herdcats_key.pub >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys', 'mac-gen')}
                      >
                        {copiedIndex === 'mac-gen' ? '✓ Copied' : 'Copy'}
                      </button>
                    </div>
                  </div>
                </li>

                <li className="step-item">
                  <div className="step-num">3</div>
                  <div className="step-body">
                    <h3>Transfer the Private Key to Herdcats</h3>
                    <p>You can bring the private key into Herdcats using either method:</p>
                    <div className="sub-options">
                      <div className="sub-option">
                        <strong>Method A (AirDrop / Files):</strong>
                        <p>AirDrop <code>~/.ssh/herdcats_key</code> (without <code>.pub</code>) to your iPhone and save to Files. In Herdcats, tap <strong>Import…</strong> and select it.</p>
                      </div>
                      <div className="sub-option">
                        <strong>Method B (Clipboard):</strong>
                        <p>Copy to clipboard: <code>cat ~/.ssh/herdcats_key | pbcopy</code>. Paste directly into the private key field in Herdcats.</p>
                      </div>
                    </div>
                  </div>
                </li>

                <li className="step-item">
                  <div className="step-num">4</div>
                  <div className="step-body">
                    <h3>Find Host &amp; Username</h3>
                    <p>In Terminal on your Mac, find your connection details:</p>
                    <ul className="info-bullets">
                      <li><strong>Username:</strong> Run <code>whoami</code> (e.g. <code>alice</code>).</li>
                      <li>
                        <strong>Host:</strong> If using Tailscale (recommended), run <code>tailscale ip -4</code> or use your MagicDNS hostname (e.g. <code>mac-mini.tailnet-name.ts.net</code>). Otherwise use your local network IP (e.g. <code>192.168.1.50</code>).
                      </li>
                      <li><strong>Port:</strong> Default is <code>22</code>.</li>
                    </ul>
                  </div>
                </li>
              </ol>
            </div>
          </div>
        )}

        {/* TAB 2: Linux */}
        {activeTab === 'linux' && (
          <div className="tab-pane">
            <div className="guide-card">
              <h2>Setting up SSH on Linux</h2>
              <p className="card-desc">
                Instructions for Ubuntu, Debian, Fedora, Arch Linux, and remote cloud VMs (AWS, GCP, Hetzner).
              </p>

              <ol className="step-list">
                <li className="step-item">
                  <div className="step-num">1</div>
                  <div className="step-body">
                    <h3>Ensure OpenSSH Server is Installed &amp; Running</h3>
                    <p>Run the package manager commands for your distribution:</p>
                    <div className="code-box">
                      <pre><code>{`# Ubuntu / Debian
sudo apt update && sudo apt install openssh-server -y
sudo systemctl enable --now ssh

# Fedora / RHEL
sudo dnf install openssh-server -y
sudo systemctl enable --now sshd

# Arch Linux
sudo pacman -S openssh
sudo systemctl enable --now sshd`}</code></pre>
                      <button
                        type="button"
                        className="copy-btn"
                        onClick={() => copyToClipboard('sudo apt update && sudo apt install openssh-server -y && sudo systemctl enable --now ssh', 'linux-install')}
                      >
                        {copiedIndex === 'linux-install' ? '✓ Copied' : 'Copy'}
                      </button>
                    </div>
                  </div>
                </li>

                <li className="step-item">
                  <div className="step-num">2</div>
                  <div className="step-body">
                    <h3>Generate &amp; Authorize Key</h3>
                    <p>Generate an ed25519 keypair and ensure correct permissions:</p>
                    <div className="code-box">
                      <pre><code>ssh-keygen -t ed25519 -N &quot;&quot; -f ~/.ssh/herdcats_key &amp;&amp; cat ~/.ssh/herdcats_key.pub &gt;&gt; ~/.ssh/authorized_keys &amp;&amp; chmod 700 ~/.ssh &amp;&amp; chmod 600 ~/.ssh/authorized_keys</code></pre>
                      <button
                        type="button"
                        className="copy-btn"
                        onClick={() => copyToClipboard('ssh-keygen -t ed25519 -N "" -f ~/.ssh/herdcats_key && cat ~/.ssh/herdcats_key.pub >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys', 'linux-keygen')}
                      >
                        {copiedIndex === 'linux-keygen' ? '✓ Copied' : 'Copy'}
                      </button>
                    </div>
                  </div>
                </li>

                <li className="step-item">
                  <div className="step-num">3</div>
                  <div className="step-body">
                    <h3>Check Firewall &amp; herdr Binary Location</h3>
                    <p>If you use a firewall like UFW:</p>
                    <div className="code-box">
                      <pre><code>sudo ufw allow ssh</code></pre>
                    </div>
                    <p style={{ marginTop: '10px' }}>
                      Ensure the <code>herdr</code> CLI binary is installed and reachable in your user&rsquo;s <code>PATH</code>, <code>~/.local/bin</code>, or <code>/usr/local/bin</code>.
                    </p>
                  </div>
                </li>
              </ol>
            </div>
          </div>
        )}

        {/* TAB 3: Windows / WSL */}
        {activeTab === 'windows' && (
          <div className="tab-pane">
            <div className="guide-card">
              <h2>Setting up SSH on Windows / WSL</h2>
              <p className="card-desc">
                For developers working on Windows, connecting via Windows Subsystem for Linux (WSL2) is the recommended path.
              </p>

              <ol className="step-list">
                <li className="step-item">
                  <div className="step-num">1</div>
                  <div className="step-body">
                    <h3>Option A: WSL 2 (Recommended)</h3>
                    <p>Open your WSL terminal (e.g. Ubuntu) and configure OpenSSH server:</p>
                    <div className="code-box">
                      <pre><code>{`sudo apt install openssh-server -y
sudo service ssh start
ssh-keygen -t ed25519 -N "" -f ~/.ssh/herdcats_key
cat ~/.ssh/herdcats_key.pub >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`}</code></pre>
                      <button
                        type="button"
                        className="copy-btn"
                        onClick={() => copyToClipboard('sudo apt install openssh-server -y && sudo service ssh start && ssh-keygen -t ed25519 -N "" -f ~/.ssh/herdcats_key && cat ~/.ssh/herdcats_key.pub >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys', 'wsl-setup')}
                      >
                        {copiedIndex === 'wsl-setup' ? '✓ Copied' : 'Copy'}
                      </button>
                    </div>
                  </div>
                </li>

                <li className="step-item">
                  <div className="step-num">2</div>
                  <div className="step-body">
                    <h3>Option B: Native Windows OpenSSH Server</h3>
                    <p>Open PowerShell as Administrator:</p>
                    <div className="code-box">
                      <pre><code>{`Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType 'Automatic'`}</code></pre>
                      <button
                        type="button"
                        className="copy-btn"
                        onClick={() => copyToClipboard('Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0; Start-Service sshd; Set-Service -Name sshd -StartupType \'Automatic\'', 'win-native')}
                      >
                        {copiedIndex === 'win-native' ? '✓ Copied' : 'Copy'}
                      </button>
                    </div>
                    <p style={{ marginTop: '8px' }}>
                      Authorize your public key in <code>%USERPROFILE%\.ssh\authorized_keys</code>.
                    </p>
                  </div>
                </li>
              </ol>
            </div>
          </div>
        )}

        {/* TAB 4: SSH Keys & Security */}
        {activeTab === 'keys' && (
          <div className="tab-pane">
            <div className="guide-card">
              <h2>SSH Key Management &amp; Security Architecture</h2>
              <p className="card-desc">
                Understanding how Herdcats handles authentication, key masking, and Keychain isolation.
              </p>

              <div className="feature-grid">
                <div className="feature-cell">
                  <h3>Why Ed25519?</h3>
                  <p>
                    Ed25519 represents modern OpenSSH standards. Keys are compact (32 bytes), extremely fast to negotiate,
                    immune to timing attacks, and supported natively by Apple CryptoKit.
                  </p>
                </div>
                <div className="feature-cell">
                  <h3>Passphrase Notice</h3>
                  <p>
                    For seamless background polling and reconnects, Herdcats requires unencrypted OpenSSH keys
                    (generate with <code>-N &quot;&quot;</code>). Use in trusted networks or Tailscale mesh.
                  </p>
                </div>
                <div className="feature-cell">
                  <h3>On-Device Keychain</h3>
                  <p>
                    Remembered passwords and keys are stored exclusively in the iOS Keychain on your physical device.
                    They are never backed up unencrypted or transmitted outside the direct SSH handshake.
                  </p>
                </div>
                <div className="feature-cell">
                  <h3>Shoulder-Surfing Protection</h3>
                  <p>
                    Herdcats masks private key text by default, displaying only the last 2 lines for verification.
                    Tap the <strong>Show</strong> toggle if you need to inspect the full key.
                  </p>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* TAB 5: Troubleshooting */}
        {activeTab === 'troubleshooting' && (
          <div className="tab-pane">
            <div className="guide-card">
              <h2>Troubleshooting &amp; Common Issues</h2>
              <p className="card-desc">
                Quick resolutions for connection, authentication, and environment issues.
              </p>

              <div className="faq-list">
                <div className="faq-item">
                  <h3>🔴 &ldquo;Authentication failed — check username and password/key&rdquo;</h3>
                  <p>
                    The SSH server rejected authentication (<code>allAuthenticationOptionsFailed</code>).
                  </p>
                  <ul>
                    <li>Verify the matching public key shown in Herdcats is in <code>~/.ssh/authorized_keys</code>.</li>
                    <li>
                      Check permissions on your remote host:
                      <br />
                      <code>chmod 700 ~/.ssh &amp;&amp; chmod 600 ~/.ssh/authorized_keys</code>
                    </li>
                    <li>Ensure you imported the <strong>private key</strong> (e.g. <code>herdcats_key</code>), not the <code>.pub</code> public key.</li>
                  </ul>
                </div>

                <div className="faq-item">
                  <h3>🔴 &ldquo;Host key verification failed / changed&rdquo;</h3>
                  <p>
                    Herdcats pins remote host key fingerprints in Keychain on first connect (Trust On First Use). If your server was reinstalled or rebuilt, the key will fail closed to prevent MITM attacks. Delete the recent connection card and re-connect to approve the new fingerprint.
                  </p>
                </div>

                <div className="faq-item">
                  <h3>🔴 Connection Timeout / Host Unreachable</h3>
                  <p>
                    If connecting over Wi-Fi, ensure your phone and computer are on the same subnet. For remote access across networks, install <strong>Tailscale</strong> on both devices to connect seamlessly via MagicDNS.
                  </p>
                </div>

                <div className="faq-item">
                  <h3>🔴 &ldquo;herdr: command not found&rdquo;</h3>
                  <p>
                    Herdcats looks for <code>herdr</code> in <code>PATH</code>, <code>~/.local/bin</code>, <code>/opt/homebrew/bin</code>, and <code>/usr/local/bin</code>. Ensure Herdr is installed on the remote machine.
                  </p>
                </div>
              </div>
            </div>
          </div>
        )}
      </main>

      {/* Footer */}
      <footer className="support-footer">
        <div className="footer-inner">
          <p>© {new Date().getFullYear()} Herdcats. Open source iOS client for Herdr.</p>
          <div className="footer-links">
            <Link href="/support" className="footer-link">Support</Link>
            <Link href="/about" className="footer-link">About</Link>
            <Link href="/privacy" className="footer-link">Privacy</Link>
            <Link href="/terms" className="footer-link">Terms</Link>
            <a
              href="https://github.com/zhiyao/herdcats"
              target="_blank"
              rel="noopener noreferrer"
              className="footer-link"
            >
              GitHub ↗
            </a>
          </div>
        </div>
      </footer>

      {/* Styles */}
      <style jsx>{`
        .support-wrapper {
          min-height: 100dvh;
          height: 100dvh;
          background: var(--bg-page);
          color: #FFFFFF;
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", "Segoe UI", Roboto, sans-serif;
          overflow-y: auto;
          -webkit-overflow-scrolling: touch;
          display: flex;
          flex-direction: column;
        }

        .support-header {
          display: flex;
          justify-content: center;
          align-items: center;
          padding: 40px 20px 16px;
        }

        .support-wrapper :global(.brand-link) {
          display: flex;
          align-items: center;
          justify-content: center;
          gap: 12px;
          text-decoration: none;
          color: #FFFFFF;
          transition: opacity 0.15s ease;
        }

        .support-wrapper :global(.brand-link:hover) {
          opacity: 0.85;
        }

        .logo {
          border-radius: 8px;
        }

        .brand-name {
          font-size: 20px;
          font-weight: 700;
          letter-spacing: -0.3px;
        }

        .support-main {
          flex: 1;
          max-width: 960px;
          width: 100%;
          margin: 0 auto;
          padding: 36px 20px 60px;
        }

        .hero-section {
          margin-bottom: 32px;
        }

        .hero-title {
          font-size: 32px;
          font-weight: 800;
          letter-spacing: -0.8px;
          background: linear-gradient(135deg, #FFFFFF 40%, #0EDCD5 100%);
          -webkit-background-clip: text;
          background-clip: text;
          -webkit-text-fill-color: transparent;
          margin-bottom: 10px;
        }

        .hero-subtitle {
          font-size: 16px;
          color: #8E8E93;
          line-height: 1.5;
          max-width: 680px;
          margin-bottom: 20px;
        }

        .security-banner {
          display: flex;
          align-items: center;
          gap: 12px;
          background: #14141F;
          border: 1px solid rgba(14, 220, 213, 0.2);
          padding: 12px 16px;
          border-radius: 12px;
          font-size: 13px;
          color: #CCCCCC;
        }

        .shield-icon {
          font-size: 20px;
        }

        .ts-tag {
          display: inline-block;
          margin-left: 10px;
          background: rgba(14, 220, 213, 0.15);
          color: #0EDCD5;
          font-size: 11px;
          font-weight: 600;
          padding: 2px 7px;
          border-radius: 4px;
        }

        /* Tabs Bar */
        .tabs-bar {
          display: flex;
          gap: 8px;
          overflow-x: auto;
          padding-bottom: 4px;
          margin-bottom: 24px;
          border-bottom: 1px solid rgba(255, 255, 255, 0.08);
        }

        .tab-btn {
          background: transparent;
          border: none;
          color: #8E8E93;
          font-size: 14px;
          font-weight: 600;
          padding: 10px 16px;
          border-radius: 8px 8px 0 0;
          cursor: pointer;
          white-space: nowrap;
          transition: all 0.15s ease;
          border-bottom: 2px solid transparent;
        }

        .tab-btn:hover {
          color: #FFFFFF;
        }

        .tab-btn.active {
          color: #0EDCD5;
          border-bottom: 2px solid #0EDCD5;
          background: rgba(14, 220, 213, 0.06);
        }

        /* Guide Card */
        .guide-card {
          background: #1F1F2E;
          border: 1px solid rgba(255, 255, 255, 0.08);
          border-radius: 16px;
          padding: 28px;
          box-shadow: 0 8px 28px rgba(0, 0, 0, 0.35);
        }

        .guide-card h2 {
          font-size: 22px;
          font-weight: 700;
          color: #FFFFFF;
          margin-bottom: 6px;
        }

        .card-desc {
          font-size: 14px;
          color: #8E8E93;
          margin-bottom: 24px;
        }

        .prereq-text {
          font-size: 13px;
          color: #CCCCCC;
          margin: -12px 0 24px;
        }

        .prereq-text a {
          color: #0EDCD5;
        }

        /* Steps */
        .step-list {
          list-style: none;
          display: flex;
          flex-direction: column;
          gap: 24px;
        }

        .step-item {
          display: flex;
          gap: 16px;
        }

        .step-num {
          width: 32px;
          height: 32px;
          border-radius: 50%;
          background: rgba(14, 220, 213, 0.15);
          color: #0EDCD5;
          font-weight: 700;
          font-size: 14px;
          display: flex;
          align-items: center;
          justify-content: center;
          flex-shrink: 0;
          margin-top: 2px;
        }

        .step-body {
          flex: 1;
        }

        .step-body h3 {
          font-size: 16px;
          font-weight: 600;
          color: #FFFFFF;
          margin-bottom: 6px;
        }

        .step-body p {
          font-size: 14px;
          color: #CCCCCC;
          line-height: 1.5;
          margin-bottom: 8px;
        }

        .path-text {
          background: #14141F;
          border: 1px solid rgba(255, 255, 255, 0.06);
          padding: 8px 12px;
          border-radius: 8px;
          font-size: 13px;
          color: #0EDCD5 !important;
        }

        .tip-text {
          font-size: 12px !important;
          color: #8E8E93 !important;
          margin-top: 4px;
        }

        /* Code box */
        .code-box {
          position: relative;
          background: #14141F;
          border: 1px solid rgba(255, 255, 255, 0.08);
          border-radius: 10px;
          padding: 12px 60px 12px 14px;
          margin: 8px 0;
          overflow-x: auto;
        }

        .code-box pre {
          margin: 0;
          font-family: ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace;
          font-size: 12px;
          color: #0EDCD5;
          line-height: 1.5;
          white-space: pre-wrap;
          word-break: break-all;
        }

        .copy-btn {
          position: absolute;
          top: 10px;
          right: 10px;
          background: rgba(255, 255, 255, 0.1);
          color: #FFFFFF;
          border: none;
          font-size: 11px;
          font-weight: 600;
          padding: 4px 10px;
          border-radius: 6px;
          cursor: pointer;
          transition: background 0.15s ease;
        }

        .copy-btn:hover {
          background: #0EDCD5;
          color: #003E43;
        }

        .sub-options {
          display: grid;
          grid-template-columns: 1fr 1fr;
          gap: 12px;
          margin-top: 8px;
        }

        .sub-option {
          background: #14141F;
          border: 1px solid rgba(255, 255, 255, 0.06);
          border-radius: 10px;
          padding: 12px;
        }

        .sub-option strong {
          display: block;
          font-size: 13px;
          color: #0EDCD5;
          margin-bottom: 4px;
        }

        .sub-option p {
          font-size: 12px;
          color: #8E8E93;
          margin: 0;
        }

        .info-bullets {
          list-style: none;
          display: flex;
          flex-direction: column;
          gap: 8px;
          margin-top: 8px;
        }

        .info-bullets li {
          font-size: 13px;
          color: #CCCCCC;
          background: #14141F;
          padding: 8px 12px;
          border-radius: 8px;
        }

        /* Feature grid */
        .feature-grid {
          display: grid;
          grid-template-columns: 1fr 1fr;
          gap: 16px;
        }

        .feature-cell {
          background: #14141F;
          border: 1px solid rgba(255, 255, 255, 0.06);
          border-radius: 12px;
          padding: 16px;
        }

        .feature-cell h3 {
          font-size: 15px;
          font-weight: 700;
          color: #0EDCD5;
          margin-bottom: 6px;
        }

        .feature-cell p {
          font-size: 13px;
          color: #8E8E93;
          line-height: 1.5;
        }

        /* FAQ */
        .faq-list {
          display: flex;
          flex-direction: column;
          gap: 16px;
        }

        .faq-item {
          background: #14141F;
          border: 1px solid rgba(255, 255, 255, 0.06);
          border-radius: 12px;
          padding: 16px;
        }

        .faq-item h3 {
          font-size: 15px;
          font-weight: 600;
          color: #FFFFFF;
          margin-bottom: 8px;
        }

        .faq-item p {
          font-size: 13px;
          color: #8E8E93;
          line-height: 1.5;
          margin-bottom: 8px;
        }

        .faq-item ul {
          padding-left: 18px;
          font-size: 13px;
          color: #CCCCCC;
          line-height: 1.6;
        }

        /* Footer */
        .support-footer {
          position: sticky;
          bottom: 0;
          z-index: 40;
          border-top: 1px solid rgba(255, 255, 255, 0.08);
          background: rgba(20, 20, 31, 0.92);
          backdrop-filter: blur(16px);
          -webkit-backdrop-filter: blur(16px);
          padding: 18px 20px;
          margin-top: auto;
        }

        .footer-inner {
          max-width: 960px;
          margin: 0 auto;
          display: flex;
          flex-direction: column;
          align-items: center;
          gap: 10px;
          text-align: center;
          font-size: 13px;
          color: #636366;
        }

        .footer-links {
          display: flex;
          justify-content: center;
          flex-wrap: wrap;
          gap: 16px;
        }

        .support-wrapper :global(.footer-link) {
          color: #8E8E93;
          text-decoration: none;
          transition: color 0.15s ease;
        }

        .support-wrapper :global(.footer-link:hover) {
          color: #0EDCD5;
        }

        @media (max-width: 640px) {
          .support-header {
            padding: 28px 16px 12px;
          }
          .sub-options, .feature-grid {
            grid-template-columns: 1fr;
          }
        }
      `}</style>
    </div>
  );
}
