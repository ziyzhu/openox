package ai.openox.ox.platform.models

import java.net.URI

sealed interface HostEndpoint {
    val url: String

    data class Remote(override val url: String) : HostEndpoint {
        override fun toString(): String = url
    }

    data object Local : HostEndpoint {
        override val url = "ox-local://device"

        override fun toString(): String = url
    }

    companion object {
        const val DEFAULT_PORT = 9876

        fun parse(value: String): Result<HostEndpoint> = runCatching {
            val trimmed = value.trim()
            require(trimmed.isNotEmpty()) { "Enter a Host address" }
            if (trimmed == Local.url) return@runCatching Local
            val withScheme = if ("://" in trimmed) trimmed else "ws://$trimmed"
            val uri = URI(withScheme)
            require(uri.scheme == "ws" || uri.scheme == "wss") { "Ox Host endpoint must be a ws:// or wss:// URL" }
            require(!uri.host.isNullOrEmpty()) { "Ox Host endpoint needs a host name" }
            val port = if (uri.port == -1 && uri.scheme == "ws") DEFAULT_PORT else uri.port
            val normalized = URI(uri.scheme, null, uri.host, port, uri.path?.ifEmpty { "/" } ?: "/", null, null)
            Remote(normalized.toString())
        }
    }
}
