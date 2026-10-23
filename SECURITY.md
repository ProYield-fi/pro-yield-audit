# Security Policy

## Reporting

Report privately to **team@proyield.fi**. Please do not open a public issue or post details before coordinated disclosure.

Include:

- contract or component, and chain;
- the commit, build, or deployed address you tested;
- a minimal reproduction or proof of concept;
- impact and preconditions;
- whether the finding is already public.

## Our commitment

- Acknowledge receipt within **48 hours**.
- Triage within **7 days**.
- Keep you updated on the fix and the disclosure date.
- Credit you by name or handle in the audit log, unless you ask to remain anonymous.
- Coordinate public disclosure with you. Our default window is **90 days from the ship date of the fix**, or earlier if a fix is live and users are protected.

## Rewards

There is **no active paid bounty program**. The old token-denominated bounty schedule is withdrawn; we do not require a token stake to submit a finding, and we do not promise token or cash payments. We offer named credit and early access to the fix for re-testing. Any future paid program will be announced in writing with clear scope, eligibility, and payment terms.

## Scope

In scope:

- mainnet ProYieldVault and FeeDistributor deployments;
- the PYD token and staking contracts, where deployed;
- the ProYield web app and API surfaces that handle funds, signatures, or user data.

Out of scope:

- testnet deployments and paper-trading environments;
- third-party infrastructure and dependencies (report those upstream);
- social engineering, phishing, physical attacks, and denial-of-service;
- issues that require compromised owner keys or a malicious Safe signer.

## Audit status

External review is in progress on the current vault and fee contracts. We will publish the final scope, commit, and report when the review is complete. Do not treat this page as a claim that the contracts are audited.
