package com.neilgoldader.planmeter.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull

/** Compares JSON by value: key order and number spelling (`1` vs `1.0`) do not matter. */
object JsonTrees {
    fun normalize(text: String): String = render(Json.parseToJsonElement(text))

    private fun render(element: JsonElement): String = when (element) {
        is JsonObject -> element.entries.sortedBy { it.key }.joinToString(",", "{", "}") { "\"${it.key}\":${render(it.value)}" }
        is JsonArray -> element.joinToString(",", "[", "]") { render(it) }
        JsonNull -> "null"
        is JsonPrimitive -> when {
            element.isString -> "\"${element.content}\""
            element.booleanOrNull != null -> element.content
            else -> element.doubleOrNull?.toString() ?: element.content
        }
    }
}
