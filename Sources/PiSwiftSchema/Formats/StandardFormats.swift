// Port of packages/schema/src/formats/index.ts at pi-mono v1.5.2.
/// The 21 standard format checks from pi-schema and TypeBox 1.3.27.
/// For `url`, `iri`, and `iri-reference`, a special-scheme URL whose host needs
/// UTS 46 mapping or validation can be accepted where Node rejects it.
/// This target ships no UTS 46 table.
public let standardFormats: [String: FormatCheck] = [
    "date": isDate,
    "date-time": isDateTime,
    "duration": isDuration,
    "email": isEmail,
    "hostname": isHostname,
    "idn-email": isIdnEmail,
    "idn-hostname": isIdnHostname,
    "ipv4": isIPv4,
    "ipv6": isIPv6,
    "iri": isIri,
    "iri-reference": isIriReference,
    "json-pointer": isJsonPointer,
    "json-pointer-uri-fragment": isJsonPointerUriFragment,
    "regex": isRegex,
    "relative-json-pointer": isRelativeJsonPointer,
    "time": { isTime($0) },
    "uri": isUri,
    "uri-reference": isUriReference,
    "uri-template": isUriTemplate,
    "url": isUrl,
    "uuid": isUuid,
]
