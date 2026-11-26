# Security

Trove keeps a clipboard history, which can hold passwords, tokens and private messages. Security reports are welcome and are handled first.

## Reporting a problem

Please report security problems **privately**: on the [Trove releases repository](https://github.com/gorkemblm/trove-releases), open the **Security** tab and choose **Report a vulnerability**. Do not open a public issue for them.

Include the Trove version (*Settings › General › Version*), your macOS version, what an attacker can do, and the steps to show it.

## What is in scope

- Reading clipboard history without the user's key: the database, image files, key file, exports, temporary files.
- Hidden items opened without Touch ID or the Mac password.
- Content that should not be saved (concealed items from password managers, ignored apps) being saved.
- The update path: Sparkle, the appcast, signatures.

How Trove protects data is described in [Privacy and security](README.md#privacy-and-security).

## Supported versions

Fixes go into the latest release. Sparkle offers it to everyone with automatic checks turned on.
