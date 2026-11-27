package ai.openox.ox.runtime.vm


class OxFunctionError(val code: String, message: String) : Exception(message)
