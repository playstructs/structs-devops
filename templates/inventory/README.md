# Inventory

What this operator runs on Structs, in the
structs-devops inventory format. Start with
`AGENTS.md`; the format is `docs/inventory.md` in the framework.

    devops site new <id> --kind guild|public-node|local --fqdn <host> --ssh root@<host>
    devops inventory discover <id>
    devops inventory validate && devops inventory render

Keep this repo private if it names hosts you would rather not publish. Secret
values never belong here in any case: `site.yaml` holds pointers only.
