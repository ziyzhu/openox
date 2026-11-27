package ai.openox.ox.remote

sealed class HostError(message: String) : Exception(message) {
    class Rpc(val code: Int, message: String) : HostError(message)

    class Unavailable(reason: String, val sent: Boolean) : HostError(
        if (sent) "$reason. The request reached the Host, so its outcome is unknown; refresh before retrying."
        else "$reason. Open Ox on the Host device, allow Host connections, and check the address."
    )

    class Invalid(message: String) : HostError(message)

    class Unsupported(revisions: List<Int>) : HostError(
        "Host RPC revisions ${revisions.joinToString().ifEmpty { "unversioned" }} do not support revision ${HostClient.RPC_VERSION}; update Ox on both devices."
    )
}
