# Example service repository

This directory is a complete repository Ox can install or serve. Copy it into
its own Git repository, replace `example.com` with the target domain, and update
`repository.json`, `service.json`, and `actions.js` together.

Validate or serve it from the OpenOx checkout:

```sh
ox repository validate examples/service-repository
ox repository serve examples/service-repository --port 8101
```

Remote repositories may contain web and MCP services. Native iOS services are
reserved for the built-in repository shipped with the app.
