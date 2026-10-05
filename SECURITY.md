# Security policy

Please report vulnerabilities privately, through GitHub's **Report a vulnerability** button on the Security tab of this repository. Don't open a public issue.

This package injects keyboard and mouse input. In scope, among others:

- a way to inject input without the host app enabling a session, or after `stop()` returns (other than releasing held keys and buttons);
- a way for input to land outside the shared surface, or into an elevated or secure-input context the package says it blocks;
- a way around the rate limits, sequence checks or session binding described in [docs/design.md](docs/design.md#11-security-model-and-threats);
- typed text, key codes or pointer positions reaching logs or errors;
- a crash or hang caused by a crafted message.
