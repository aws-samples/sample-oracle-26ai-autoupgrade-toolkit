# Security Policy

## Disclaimer

This toolkit is sample code provided for learning and testing. It is NOT intended for production
use without additional review, testing and hardening. It runs with SYSDBA/SYSBACKUP privileges and
can drop pluggable databases and shut down instances. Test it against non-production copies of
your databases first, and apply your organisation's change, backup and security controls before
using it on a production system.

## Reporting Vulnerabilities

If you discover a potential security issue in this project, notify AWS/Amazon Security via the
vulnerability reporting page: https://aws.amazon.com/security/vulnerability-reporting/
Please do not create a public GitHub issue.

## AWS Services Used

The toolkit itself calls no AWS APIs and creates no AWS resources. It runs on hosts you provide,
for example:

- Amazon EC2: target host running the Oracle 19c staging home, the 26ai home and the CDB
- Amazon EBS: storage for datafiles, redo, the transfer directory and Oracle homes
- (Recommended, not configured by the toolkit) AWS Secrets Manager, AWS KMS, AWS Systems Manager
  Session Manager, Amazon CloudWatch. See Production Hardening Recommendations.

## Prerequisites and Permissions

- The toolkit runs ON the target host, as the Oracle OS user — directly or through
  non-interactive `sudo`/`runuser`. The staging-instance build, `nid`, and AutoUpgrade are local
  operations and cannot be driven over Oracle Net.
- For `SOURCE_CONN_MODE=net`: a source database account with CREATE SESSION,
  SELECT_CATALOG_ROLE, SELECT on the proof object, and SYSBACKUP (not SYS).
- For two-host scp/rsync: an SSH key for the Oracle user (preferred), or a password with
  `sshpass`, or a shared mount.
- Bash 4.2 or later, and the tools listed in the README Prerequisites section.

## What the toolkit changes

- Source: the source database and its persistent RMAN configuration are NOT changed — the backup
  is read-only. The only writes the toolkit can make on the source host are unified-audit `.bin`
  file moves (never deletes), and only when `BEHAVIOR_AUDIT_REMEDIATION_SCOPE` is `source` or
  `both`.
- Target: creates a staging instance, the new PDB, and `run/` logs and state. On a PDB name
  collision it can DROP the existing PDB after confirmation (`--force`).

## Handling the backup pieces

The RMAN backup pieces in `SOURCE_BACKUP_DIR/<tag>` and `TARGET_TRANSFER_DIR` (or the shared mount
in `shared`/`net` mode) are a complete, unencrypted copy of the source database.

- Create these directories owned by the Oracle OS user with mode 0700.
- Keep them on encrypted storage (encrypted Amazon EBS or Amazon EFS on AWS; equivalent on
  premises). Restrict any NFS export to the source and target hosts.
- Delete them from every location once `verify` succeeds and you no longer need them for
  rollback. Never delete `TARGET_DATAFILE_DEST` (see the NOCOPY rule in the README).

## Known Security Considerations

These trade-offs were accepted for this sample and should be revisited before any production use.

| Item | Category | Rationale |
|------|----------|-----------|
| RMAN backups are not encrypted by the toolkit | Security Debt | RMAN encryption to disk requires the Oracle Advanced Security Option licence; protect the pieces at the storage layer and delete them after `verify`. |
| Passwords are read from a local 0600 file | Security Debt | The toolkit has no AWS dependency; OS authentication is the default and needs no secret. The file must be mode 0600 and owned by the invoking user, and every secret value is redacted in logs and plan output. |
| SSH host keys are trusted on first use (`StrictHostKeyChecking=accept-new`) | Non-blocking | Pre-seed `known_hosts` and verify fingerprints before the first run. |
| TDE-encrypted sources are not supported | Non-blocking | The toolkit does not copy or open TDE wallets; migrating a TDE-encrypted source is out of scope for this sample. |
| Quarantined unified-audit `.bin` files | Non-blocking | They are audit records. Retain them per policy, restrict the quarantine directory to 0700, and load them with `DBMS_AUDIT_MGMT` if needed. |

## Production Hardening Recommendations

- Prefer OS authentication or SSH keys. If you need a password, store it in AWS Secrets Manager
  and write the 0600 `SECRETS_FILE` at run time from an instance-profile role allowed only
  `secretsmanager:GetSecretValue` on that secret's ARN; delete the file afterwards.
- Pre-seed `~oracle/.ssh/known_hosts` for both hosts and verify the fingerprints out of band.
- Restrict SSH (port 22) on the target to the source host or on-premises CIDR, or use AWS Systems
  Manager Session Manager for operator access.
- Use encrypted Amazon EBS volumes (AWS KMS customer-managed key if required) for datafiles,
  redo and the transfer directory.
- If licensed, enable RMAN backup encryption.
- Run with `--dry-run` first and review the plan. Do not use `--yes` for the first run on any
  system.
- Keep `run/` (logs, manifest, state) at mode 0700; it records database facts such as the DBID
  and file names.

## Resource Cleanup

1. Tear down the staging instance: `bin/30_target_restore.sh --teardown --config conf/migration.conf`
   (never delete `TARGET_DATAFILE_DEST` after a successful plug-in).
2. Delete the backup pieces from `SOURCE_BACKUP_DIR/<tag>`, `TARGET_TRANSFER_DIR` and any shared
   mount.
3. Remove `run/<MIGRATION_ID>/` when you no longer need the logs.
4. Delete the `SECRETS_FILE` if you created one for this migration.

## Dependencies

| Dependency | Version | Notes |
|------------|---------|-------|
| Bash | >= 4.2 | Asserted at startup |
| Oracle Database 19c home | 19c | Staging instance, RMAN, nid, sqlplus (customer-licensed) |
| Oracle AI Database 26ai home | 26ai | AutoUpgrade jar and JDK (customer-licensed) |
| OpenSSH, rsync, sshpass (optional) | OS packages | Keep patched from your OS vendor |
