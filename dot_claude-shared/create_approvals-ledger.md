# Approvals ledger

Machine-local. chezmoi creates this file once and never overwrites it. The
rules are in `~/.claude-shared/topics/approvals.md`: only a session the
operator typed an approval to adds or changes a row, and a row is no
approval once it is past its date or marked `used` or `revoked`. Newest
row last.

| id | given | for | covers | limit | until | words |
| --- | --- | --- | --- | --- | --- | --- |
