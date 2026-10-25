// Ported from pi-mono v1.3.0 packages/codemode/src/runtime/vm.ts.
// JavaScriptCore has no per-context clock or time zone. Install these bindings before lockdown.
let codemodeDeterministicPreludeSource = #"""
(function (startedAt, seed) {
	"use strict";

	const NativeDate = globalThis.Date;
	const datePrototype = NativeDate.prototype;
	const nativeParse = NativeDate.parse;
	const nativeUTC = NativeDate.UTC;
	const getTime = datePrototype.getTime;
	const getUTCFullYear = datePrototype.getUTCFullYear;
	const getUTCMonth = datePrototype.getUTCMonth;
	const getUTCDate = datePrototype.getUTCDate;
	const getUTCDay = datePrototype.getUTCDay;
	const getUTCHours = datePrototype.getUTCHours;
	const getUTCMinutes = datePrototype.getUTCMinutes;
	const getUTCSeconds = datePrototype.getUTCSeconds;
	const setTime = datePrototype.setTime;
	const setUTCFullYear = datePrototype.setUTCFullYear;
	const nativeLocaleString = datePrototype.toLocaleString;
	const nativeLocaleDateString = datePrototype.toLocaleDateString;
	const nativeLocaleTimeString = datePrototype.toLocaleTimeString;
	const apply = Reflect.apply;
	const construct = Reflect.construct;
	const define = Object.defineProperty;
	const isFinite = Number.isFinite;
	const imul = Math.imul;
	const round = Math.round;
	const nativeCanonicalLocales = typeof Intl === "object" ? Intl.getCanonicalLocales : undefined;
	let now = startedAt;
	let state = seed >>> 0;

	function replace(object, key, value) {
		define(object, key, { value, writable: true, configurable: true, enumerable: false });
	}

	// An empty or unsupported locale list must not select the host locale.
	function fixedLocales(locales) {
		if (typeof nativeCanonicalLocales !== "function") {
			throw new TypeError("Deterministic locale formatting requires Intl.getCanonicalLocales");
		}
		const result = apply(nativeCanonicalLocales, Intl, [locales]);
		if (!result.includes("en-US")) result.push("en-US");
		return result;
	}

	function constructorProperties(wrapper, native) {
		wrapper.prototype = native.prototype;
		replace(native.prototype, "constructor", wrapper);
		for (const key of Reflect.ownKeys(native)) {
			if (key === "prototype" || key === "caller" || key === "arguments") continue;
			define(wrapper, key, Object.getOwnPropertyDescriptor(native, key));
		}
	}

	// Date-only ISO input is UTC. Add a zone to ISO input with a time but no zone.
	// Accept only complete ISO and standard Date string forms. Other legacy input is invalid.
	function parse(value) {
		if (typeof value === "symbol") throw new TypeError("Cannot convert a Symbol value to a string");
		const text = String(value).trim();
		if (/^(?:\d{4}|[+-]\d{6})-\d{2}-\d{2}[Tt]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?$/.test(text)) {
			return apply(nativeParse, NativeDate, [text + "Z"]);
		}
		if (/^(?:\d{4}|[+-]\d{6})(?:-\d{2}(?:-\d{2})?)?$/.test(text) ||
			/^(?:\d{4}|[+-]\d{6})-\d{2}-\d{2}[Tt]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:[Zz]|[+-]\d{2}:?\d{2})$/.test(text) ||
			/^(?:Sun|Mon|Tue|Wed|Thu|Fri|Sat), \d{2} (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) -?\d{4,6} \d{2}:\d{2}:\d{2} GMT$/.test(text) ||
			/^(?:Sun|Mon|Tue|Wed|Thu|Fri|Sat) (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{2} -?\d{4,6} \d{2}:\d{2}:\d{2} GMT[+-]\d{4}(?: \([^()\r\n]*\))?$/.test(text)) {
			return apply(nativeParse, NativeDate, [text]);
		}
		return NaN;
	}

	function primitive(value) {
		if (value === null || (typeof value !== "object" && typeof value !== "function")) return value;
		const convert = value[Symbol.toPrimitive];
		if (convert !== undefined && convert !== null) {
			const result = apply(convert, value, ["default"]);
			if (result === null || (typeof result !== "object" && typeof result !== "function")) return result;
			throw new TypeError("Cannot convert object to primitive value");
		}
		for (const key of ["valueOf", "toString"]) {
			if (typeof value[key] !== "function") continue;
			const result = apply(value[key], value, []);
			if (result === null || (typeof result !== "object" && typeof result !== "function")) return result;
		}
		throw new TypeError("Cannot convert object to primitive value");
	}

	function Date(...args) {
		if (!new.target) return apply(datePrototype.toString, new NativeDate(round(now)), []);
		let value;
		if (args.length === 0) value = round(now);
		else if (args.length > 1) value = apply(nativeUTC, NativeDate, args);
		else {
			let isDate = false;
			if (args[0] !== null && (typeof args[0] === "object" || typeof args[0] === "function")) {
				try {
					value = apply(getTime, args[0], []);
					isDate = true;
				} catch {}
			}
			if (!isDate) {
				value = primitive(args[0]);
				if (typeof value === "string") value = parse(value);
			}
		}
		return construct(NativeDate, [value], new.target);
	}
	// Do not leave the native constructor on a prototype or in the constructor chain.
	Date.prototype = datePrototype;
	replace(datePrototype, "constructor", Date);
	replace(Date, "now", () => round(now));
	replace(Date, "parse", parse);
	replace(Date, "UTC", nativeUTC);
	define(Date, "length", { value: 7, configurable: true });

	for (const suffix of ["FullYear", "Month", "Date", "Day", "Hours", "Minutes", "Seconds", "Milliseconds"]) {
		replace(datePrototype, "get" + suffix, datePrototype["getUTC" + suffix]);
		if (suffix !== "Day") replace(datePrototype, "set" + suffix, datePrototype["setUTC" + suffix]);
	}
	replace(datePrototype, "getTimezoneOffset", function getTimezoneOffset() {
		return Number.isNaN(apply(getTime, this, [])) ? NaN : 0;
	});
	replace(datePrototype, "getYear", function getYear() {
		return apply(getUTCFullYear, this, []) - 1900;
	});
	replace(datePrototype, "setYear", function setYear(year) {
		const current = apply(getTime, this, []);
		let number = +year;
		if (!Number.isNaN(number)) {
			number = Math.trunc(number);
			if (number >= 0 && number <= 99) number += 1900;
			if (Number.isNaN(current)) apply(setTime, this, [0]);
		}
		return apply(setUTCFullYear, this, [number]);
	});

	const weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
	const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
	const pad = (value, width) => String(value).padStart(width, "0");
	function dateString(value) {
		if (Number.isNaN(apply(getTime, value, []))) return "Invalid Date";
		const year = apply(getUTCFullYear, value, []);
		return weekdays[apply(getUTCDay, value, [])] + " " + months[apply(getUTCMonth, value, [])] + " " +
			pad(apply(getUTCDate, value, []), 2) + " " + (year < 0 ? "-" : "") + pad(Math.abs(year), 4);
	}
	function timeString(value) {
		if (Number.isNaN(apply(getTime, value, []))) return "Invalid Date";
		return pad(apply(getUTCHours, value, []), 2) + ":" + pad(apply(getUTCMinutes, value, []), 2) + ":" +
			pad(apply(getUTCSeconds, value, []), 2) + " GMT+0000 (Coordinated Universal Time)";
	}
	replace(datePrototype, "toDateString", function toDateString() { return dateString(this); });
	replace(datePrototype, "toTimeString", function toTimeString() { return timeString(this); });
	replace(datePrototype, "toString", function toString() {
		if (Number.isNaN(apply(getTime, this, []))) return "Invalid Date";
		return dateString(this) + " " + timeString(this);
	});

	function utcOptions(options) {
		if (options === null) throw new TypeError("Options must not be null");
		const source = options === undefined ? Object.create(null) : Object(options);
		const result = Object.create(source);
		const zone = source.timeZone;
		define(result, "timeZone", { value: zone === undefined ? "UTC" : zone, configurable: true });
		return result;
	}
	for (const [key, method] of [
		["toLocaleString", nativeLocaleString],
		["toLocaleDateString", nativeLocaleDateString],
		["toLocaleTimeString", nativeLocaleTimeString],
	]) {
		replace(datePrototype, key, function (locales, options) {
			return apply(method, this, [fixedLocales(locales), utcOptions(options)]);
		});
	}
	replace(globalThis, "Date", Date);

	// Intl can read the clock when no date is supplied. Keep that path on virtual time too.
	if (typeof Intl === "object" && typeof Intl.DateTimeFormat === "function") {
		const NativeDateTimeFormat = Intl.DateTimeFormat;
		const formatPrototype = NativeDateTimeFormat.prototype;
		const nativeFormat = Object.getOwnPropertyDescriptor(formatPrototype, "format").get;
		const nativeFormatToParts = formatPrototype.formatToParts;
		const formats = new WeakMap();
		function DateTimeFormat(locales, options) {
			const args = [fixedLocales(locales), utcOptions(options)];
			return new.target ? construct(NativeDateTimeFormat, args, new.target) :
				apply(NativeDateTimeFormat, this, args);
		}
		constructorProperties(DateTimeFormat, NativeDateTimeFormat);
		define(formatPrototype, "format", {
			configurable: true,
			get() {
				const native = apply(nativeFormat, this, []);
				let format = formats.get(this);
				if (!format) {
					format = (value) => native(value === undefined ? round(now) : value);
					formats.set(this, format);
				}
				return format;
			},
		});
		if (typeof nativeFormatToParts === "function") {
			replace(formatPrototype, "formatToParts", function formatToParts(value) {
				return apply(nativeFormatToParts, this, [value === undefined ? round(now) : value]);
			});
		}
		replace(Intl, "DateTimeFormat", DateTimeFormat);
	}

	if (typeof Intl === "object") {
		for (const key of ["Collator", "NumberFormat", "PluralRules", "RelativeTimeFormat", "ListFormat",
			"Segmenter", "DisplayNames", "DurationFormat"]) {
			const NativeConstructor = Intl[key];
			if (typeof NativeConstructor !== "function") continue;
			function LocaleConstructor(locales, ...rest) {
				const args = [fixedLocales(locales), ...rest];
				return new.target ? construct(NativeConstructor, args, new.target) :
					apply(NativeConstructor, this, args);
			}
			constructorProperties(LocaleConstructor, NativeConstructor);
			replace(Intl, key, LocaleConstructor);
		}
	}

	for (const prototype of [Number.prototype, ...(typeof BigInt === "function" ? [BigInt.prototype] : [])]) {
		const method = prototype.toLocaleString;
		replace(prototype, "toLocaleString", function toLocaleString(locales, options) {
			return apply(method, this, [fixedLocales(locales), options]);
		});
	}
	const nativeLocaleCompare = String.prototype.localeCompare;
	replace(String.prototype, "localeCompare", function localeCompare(that, locales, options) {
		return apply(nativeLocaleCompare, this, [that, fixedLocales(locales), options]);
	});
	for (const key of ["toLocaleLowerCase", "toLocaleUpperCase"]) {
		const method = String.prototype[key];
		replace(String.prototype, key, function (locales) {
			return apply(method, this, [fixedLocales(locales)]);
		});
	}

	replace(globalThis, "performance", {
		now: () => round(now - startedAt),
		timeOrigin: startedAt,
		toJSON: () => ({ timeOrigin: startedAt }),
	});
	replace(Math, "random", function random() {
		state = (state + 0x6d2b79f5) >>> 0;
		let value = imul(state ^ (state >>> 15), 1 | state);
		value = (value + imul(value ^ (value >>> 7), 61 | value)) ^ value;
		return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
	});
	delete globalThis.WeakRef;
	delete globalThis.FinalizationRegistry;
	// Some JSC versions supply another native clock through Temporal.Now.
	delete globalThis.Temporal;

	// The worker keeps this function in a private JSValue. Do not add it to a global.
	return function advance(value) {
		if (isFinite(value) && value > now) now = value;
	};
})
"""#
