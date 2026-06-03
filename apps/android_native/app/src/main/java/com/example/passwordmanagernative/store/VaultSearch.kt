package com.example.passwordmanagernative.store

import com.example.passwordmanagernative.model.CredentialPayload
import com.example.passwordmanagernative.model.ServerPayload
import com.example.passwordmanagernative.model.ServicePayload
import com.example.passwordmanagernative.model.VaultEntry
import com.example.passwordmanagernative.model.VaultEntryType
import com.example.passwordmanagernative.model.VaultPayload

internal data class VaultSearchTerm(
    val field: String?,
    val value: String,
)

internal fun parseVaultSearchTerms(raw: String): List<VaultSearchTerm> =
    raw.trim()
        .split(Regex("[\\s,]+"))
        .mapNotNull { part ->
            val token = part.trim()
            when {
                token.isEmpty() -> null
                token.startsWith("#") && token.length > 1 -> VaultSearchTerm("tag", token.drop(1).lowercase())
                token.contains(':') -> {
                    val key = token.substringBefore(':').trim()
                    val value = token.substringAfter(':').trim()
                    if (key.isEmpty() || value.isEmpty()) {
                        null
                    } else if (key.equals("http", ignoreCase = true) || key.equals("https", ignoreCase = true)) {
                        VaultSearchTerm(null, token.lowercase())
                    } else {
                        VaultSearchTerm(canonicalSearchField(key), value.lowercase())
                    }
                }
                else -> VaultSearchTerm(null, token.lowercase())
            }
        }

internal fun VaultEntry.matchesSearchTerms(terms: List<VaultSearchTerm>): Boolean =
    terms.all { term -> matchesSearchTerm(term) }

private fun VaultEntry.matchesSearchTerm(term: VaultSearchTerm): Boolean {
    val values = when (term.field) {
        null -> searchableValues(includeSecrets = false)
        "label" -> listOf(label)
        "name" -> listOf(label) + payload.nameValues() + customFieldValuesFor("name")
        "type" -> listOf(type.name, type.title)
        "category" -> listOf(payload.category)
        "tag" -> payload.tags
        "username" -> payload.usernameValues() + customFieldValuesFor("username")
        "ip" -> payload.ipValues() + customFieldValuesFor("ip")
        "port" -> payload.portValues() + customFieldValuesFor("port")
        "address" -> payload.addressValues() + customFieldValuesFor("address")
        "app" -> payload.appValues() + customFieldValuesFor("app")
        "account" -> payload.accountValues() + customFieldValuesFor("account")
        "server" -> serverValues() + customFieldValuesFor("server")
        "service" -> serviceValues() + customFieldValuesFor("service")
        "notes" -> payload.notesValues() + customFieldValuesFor("notes")
        "password" -> payload.passwordValues() + customFieldValuesFor("password")
        "token" -> payload.tokenValues() + customFieldValuesFor("token")
        "accesskey" -> payload.accessKeyValues() + customFieldValuesFor("accesskey")
        "secret" -> payload.secretValues() + customFieldValuesFor("secret")
        "custom" -> customFields.flatMap { listOf(it.name, it.value) }
        else -> customFieldValuesFor(term.field)
    }
    return values.any { it.contains(term.value, ignoreCase = true) }
}

private fun canonicalSearchField(raw: String): String =
    when (raw.compactSearchKey()) {
        "title", "label" -> "label"
        "name" -> "name"
        "type", "kind" -> "type"
        "category", "cat" -> "category"
        "tag", "tags" -> "tag"
        "user", "username", "login" -> "username"
        "ip", "ipaddress" -> "ip"
        "port" -> "port"
        "address", "addr", "host", "url", "connection", "connectionaddress" -> "address"
        "app", "appid", "application" -> "app"
        "account", "accountid" -> "account"
        "server", "servers", "serverid", "serverids", "srv" -> "server"
        "service", "svc" -> "service"
        "note", "notes" -> "notes"
        "password", "pass", "pwd" -> "password"
        "token" -> "token"
        "access", "accesskey", "ak" -> "accesskey"
        "secret", "secretkey", "sk" -> "secret"
        "field", "custom" -> "custom"
        else -> raw.compactSearchKey()
    }

private fun String.compactSearchKey(): String =
    lowercase().filter { it.isLetterOrDigit() }

private fun VaultEntry.searchableValues(includeSecrets: Boolean): List<String> =
    buildList {
        add(label)
        add(type.name)
        add(type.title)
        add(payload.category)
        addAll(payload.tags)
        addAll(payload.searchableValues(includeSecrets))
        customFields.forEach { field ->
            add(field.name)
            add(field.value)
        }
    }

private fun VaultEntry.customFieldValuesFor(field: String): List<String> {
    val key = canonicalSearchField(field)
    return customFields
        .filter { customField ->
            val customKey = canonicalSearchField(customField.name)
            customKey.isNotEmpty() && (customKey == key || customKey.contains(key) || key.contains(customKey))
        }
        .flatMap { listOf(it.name, it.value) }
}

private fun VaultEntry.serverValues(): List<String> =
    buildList {
        if (type == VaultEntryType.SERVER) add(label)
        addAll(payload.serverValues())
    }

private fun VaultEntry.serviceValues(): List<String> =
    buildList {
        if (type == VaultEntryType.SERVICE) add(label)
        addAll(payload.serviceValues())
    }

private fun VaultPayload.searchableValues(includeSecrets: Boolean): List<String> =
    when (this) {
        is VaultPayload.Credential -> value.searchableValues(includeSecrets)
        is VaultPayload.Server -> value.searchableValues(includeSecrets)
        is VaultPayload.Service -> value.searchableValues(includeSecrets)
    }

private fun VaultPayload.nameValues(): List<String> = when (this) {
    is VaultPayload.Credential -> emptyList()
    is VaultPayload.Server -> listOf(value.name)
    is VaultPayload.Service -> listOf(value.name)
}

private fun VaultPayload.usernameValues(): List<String> = when (this) {
    is VaultPayload.Credential -> listOf(value.username)
    is VaultPayload.Server -> listOf(value.username)
    is VaultPayload.Service -> value.accounts.map { it.username }
}

private fun VaultPayload.ipValues(): List<String> = when (this) {
    is VaultPayload.Credential -> emptyList()
    is VaultPayload.Server -> listOf(value.ipAddress)
    is VaultPayload.Service -> listOf(value.connectionAddress)
}

private fun VaultPayload.portValues(): List<String> = when (this) {
    is VaultPayload.Credential -> emptyList()
    is VaultPayload.Server -> listOf(value.port)
    is VaultPayload.Service -> listOf(value.connectionPort)
}

private fun VaultPayload.addressValues(): List<String> = when (this) {
    is VaultPayload.Credential -> emptyList()
    is VaultPayload.Server -> listOf(value.ipAddress, value.location)
    is VaultPayload.Service -> listOf(value.connectionAddress)
}

private fun VaultPayload.appValues(): List<String> = when (this) {
    is VaultPayload.Credential -> listOf(value.appId)
    is VaultPayload.Server -> emptyList()
    is VaultPayload.Service -> emptyList()
}

private fun VaultPayload.accountValues(): List<String> = when (this) {
    is VaultPayload.Credential -> emptyList()
    is VaultPayload.Server -> listOfNotNull(value.accountId)
    is VaultPayload.Service -> listOfNotNull(value.accountId) + value.accounts.flatMap { listOf(it.username, it.note) }
}

private fun VaultPayload.serverValues(): List<String> = when (this) {
    is VaultPayload.Credential -> emptyList()
    is VaultPayload.Server -> listOf(value.name, value.ipAddress)
    is VaultPayload.Service -> value.serverIds
}

private fun VaultPayload.serviceValues(): List<String> = when (this) {
    is VaultPayload.Credential -> emptyList()
    is VaultPayload.Server -> emptyList()
    is VaultPayload.Service -> listOf(value.name, value.connectionAddress)
}

private fun VaultPayload.notesValues(): List<String> = when (this) {
    is VaultPayload.Credential -> listOf(value.notes)
    is VaultPayload.Server -> listOf(value.notes)
    is VaultPayload.Service -> listOf(value.notes) + value.accounts.map { it.note }
}

private fun VaultPayload.passwordValues(): List<String> = when (this) {
    is VaultPayload.Credential -> listOf(value.password)
    is VaultPayload.Server -> listOf(value.password)
    is VaultPayload.Service -> value.accounts.map { it.password }
}

private fun VaultPayload.tokenValues(): List<String> = when (this) {
    is VaultPayload.Credential -> listOf(value.token)
    is VaultPayload.Server -> emptyList()
    is VaultPayload.Service -> emptyList()
}

private fun VaultPayload.accessKeyValues(): List<String> = when (this) {
    is VaultPayload.Credential -> listOf(value.accessKey)
    is VaultPayload.Server -> emptyList()
    is VaultPayload.Service -> emptyList()
}

private fun VaultPayload.secretValues(): List<String> = when (this) {
    is VaultPayload.Credential -> listOf(value.secretKey)
    is VaultPayload.Server -> emptyList()
    is VaultPayload.Service -> emptyList()
}

private fun CredentialPayload.searchableValues(includeSecrets: Boolean): List<String> =
    buildList {
        add(username)
        add(appId)
        add(notes)
        if (includeSecrets) {
            add(password)
            add(token)
            add(accessKey)
            add(secretKey)
        }
    }

private fun ServerPayload.searchableValues(includeSecrets: Boolean): List<String> =
    buildList {
        add(name)
        add(ipAddress)
        add(port)
        add(username)
        add(basicConfig)
        add(operatingSystem)
        add(location)
        add(notes)
        accountId?.let(::add)
        if (includeSecrets) add(password)
    }

private fun ServicePayload.searchableValues(includeSecrets: Boolean): List<String> =
    buildList {
        add(name)
        add(connectionAddress)
        add(connectionPort)
        accountId?.let(::add)
        addAll(serverIds)
        add(notes)
        accounts.forEach { account ->
            add(account.username)
            add(account.note)
            if (includeSecrets) add(account.password)
        }
    }
