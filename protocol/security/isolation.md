# Isolation

The VM has no ambient network, device, shell, or Host filesystem authority.
Browser-backed services execute against their own allowed domain and retain web
credentials in the website data store. Repository source is data until the Host
validates and installs it into a bounded service runtime.

Profile mounts expose only declared virtual entries. Local, built-in, remote,
and development repositories remain separate sources with explicit precedence
and write policy.
