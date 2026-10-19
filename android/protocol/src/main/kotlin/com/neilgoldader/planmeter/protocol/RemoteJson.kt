package com.neilgoldader.planmeter.protocol

import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationStrategy
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.serializer
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.time.temporal.ChronoUnit
import java.util.Base64
import java.util.Locale

/**
 * JSON as the Swift side writes it with `RemoteJSON`: `JSONEncoder` with
 * `.iso8601` dates, default (standard, padded base64) `Data`, sorted keys, and
 * optionals omitted when nil.
 */
object RemoteJson {
    val json: Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        encodeDefaults = true
    }

    fun <T> encode(serializer: SerializationStrategy<T>, value: T): ByteArray =
        encodeToString(serializer, value).toByteArray(Charsets.UTF_8)

    fun <T> encodeToString(serializer: SerializationStrategy<T>, value: T): String =
        sortKeys(json.encodeToJsonElement(serializer, value)).toString()

    inline fun <reified T> encode(value: T): ByteArray = encode(serializer<T>(), value)

    fun <T> decode(deserializer: DeserializationStrategy<T>, bytes: ByteArray): T =
        json.decodeFromString(deserializer, bytes.toString(Charsets.UTF_8))

    inline fun <reified T> decode(bytes: ByteArray): T = decode(serializer<T>(), bytes)

    /** Same order as Swift's `.sortedKeys` for the ASCII keys this protocol uses. */
    fun sortKeys(element: JsonElement): JsonElement = when (element) {
        is JsonObject -> JsonObject(element.entries.sortedBy { it.key }.associate { it.key to sortKeys(it.value) })
        is JsonArray -> JsonArray(element.map(::sortKeys))
        else -> element
    }
}

/** Swift `Data`: standard alphabet with padding. */
object Base64DataSerializer : KSerializer<ByteArray> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("planmeter.Data", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: ByteArray) = encoder.encodeString(Base64.getEncoder().encodeToString(value))
    override fun deserialize(decoder: Decoder): ByteArray {
        val text = decoder.decodeString()
        return try {
            Base64.getDecoder().decode(text)
        } catch (e: IllegalArgumentException) {
            throw kotlinx.serialization.SerializationException("Invalid base64 data", e)
        }
    }
}

/**
 * Swift `.iso8601`: `2026-10-19T12:00:00Z`, UTC, whole seconds. Decoding also
 * accepts fractional seconds and explicit offsets, which other hosts may send.
 */
object Iso8601InstantSerializer : KSerializer<Instant> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("planmeter.Date", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: Instant) = encoder.encodeString(Iso8601.format(value))
    override fun deserialize(decoder: Decoder): Instant {
        val text = decoder.decodeString()
        return Iso8601.parse(text) ?: throw kotlinx.serialization.SerializationException("Invalid ISO-8601 date: $text")
    }
}

object Iso8601 {
    private val formatter: DateTimeFormatter =
        DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss'Z'", Locale.ROOT).withZone(ZoneOffset.UTC)

    fun format(instant: Instant): String = formatter.format(instant.truncatedTo(ChronoUnit.SECONDS))

    fun parse(text: String): Instant? = try {
        OffsetDateTime.parse(text.trim(), DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant()
    } catch (_: DateTimeParseException) {
        null
    }
}

/** Base64url without padding, as `Data.base64URLEncodedString()` in Pairing.swift. */
object Base64Url {
    fun encode(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    /** Mirrors `Data(base64URLEncoded:)`: map the alphabet, pad, then decode strictly. */
    fun decode(text: String): ByteArray? {
        val standard = StringBuilder(text.replace('-', '+').replace('_', '/'))
        while (standard.length % 4 != 0) standard.append('=')
        return try {
            Base64.getDecoder().decode(standard.toString())
        } catch (_: IllegalArgumentException) {
            null
        }
    }
}
