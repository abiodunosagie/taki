# Security

Taki runs on your Mac only. It has no server, no account and no analytics. It reads process
lists, listening ports, Docker's container list and the session files Claude Code and Codex
keep in your home folder; it writes its own settings readable by your user only, and keeps
workspace environment variables in the Keychain. The short-link proxy listens on this Mac only
and refuses other machines.

If you find a security problem, please open a private report through GitHub's
"Report a vulnerability" button on this repository rather than a public issue. Include the
macOS version, what you did and what happened. You will get an answer within a week.
