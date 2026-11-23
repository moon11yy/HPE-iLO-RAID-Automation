# Security and operational safety

This project performs privileged out-of-band storage operations and must only be used on systems you are authorized to manage.

## Authentication and secrets

- Use least-privileged iLO accounts with the specific storage configuration permissions needed for the task.
- Never commit actual host inventories, credentials, tokens, certificate private keys, discovery exports, or reports.
- The built-in CLIXML credential workflow uses Windows DPAPI and requires the **same user and computer** that exported the credential files.
- If both local credential files are present, the script may try the secondary after an explicit HTTP 401 response. Avoid repeated authentication attempts; this can lock accounts.

## HTTPS

- Prefer trusted TLS certificates and validated hostnames.
- `-SkipCertificateCheck` does **not** validate iLO identity, even though HTTPS remains encrypted. Using it for login or storage writes exposes the session to server impersonation risk. Restrict it to explicitly approved circumstances on independently verified management networks; certificate pinning is a more secure alternative when valid certificates are unavailable.

## Storage writes

- Creating volumes can destroy data and potentially impact boot order or provisioning.
- Dry Run does not write volumes. `-Apply` requires an additional typed confirmation.
- Existing volume layouts are inspected and skipped if partial or unexpected.
- After an uncertain POST or timeout, do not retry automatically. Manually inspect the live Volume collection and drive membership before any further action.
- Verify that controller firmware supports Redfish volume creation and that selected disks have been approved for erasure.

## Disclosure

For security concerns in a public fork, use the repository host's private vulnerability reporting if it is configured, rather than posting private infrastructure information in issues.
