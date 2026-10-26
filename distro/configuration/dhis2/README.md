# DHIS2 mapping shipped with the distribution

`dhis2-mapping.json` is the mapping the SSEMR DHIS2 module loads on startup, so the DHIS2 dashboard
(System Administration > DHIS2) opens on these data sets without anyone importing a file.

When it is loaded:

- On a new install, the first time OpenMRS starts.
- Whenever this file changes, as long as nobody has edited the mapping on the dashboard since it
  was last loaded. Edits made on the dashboard are never overwritten silently: the module keeps them
  and logs a warning. To load the file over them, set the global property
  `ssemrdhis2.configuration.overwriteDashboardEdits` to `true` and restart.

Each load is saved as a normal mapping revision with the note "Loaded from
configuration/dhis2/dhis2-mapping.json", so it can be seen and restored from the dashboard.

To capture a mapping configured on a server's dashboard into this file:

```bash
./scripts/export-dhis2-mapping.sh https://<server> <username>
```

Review the change with `git diff`, then commit it. Every server deployed afterwards gets it.
