#!/usr/bin/env python3
"""Bounded, category-only URI/host classification for release payloads.

The helper is deliberately independent of the shell scanner's finite regular
expressions. It discovers URI-looking tokens for arbitrary schemes, parses
their authority with the Python standard library, and normalizes IP literals
with :mod:`ipaddress`. Its stdout protocol is exactly one category line:

  exit 0 / PASS                         no unsafe URI was found
  exit 1 / PROHIBITED_PRIVATE_ENDPOINT  local/private URI or userinfo found
  exit 2 / UNVERIFIABLE_SURFACE_URI     malformed or ambiguous URI/input

Tool/input failures return 3 without output. No URI, token, or input path is
ever printed by this program.
"""

from __future__ import annotations

import ipaddress
import re
import stat
import sys
from pathlib import Path
from urllib.parse import unquote_to_bytes, urlsplit


MAX_INPUT_BYTES = 64 * 1024 * 1024
MAX_TOKEN_BYTES = 8192
MAX_URI_COUNT = 4096
MAX_SCHEME_LENGTH = 64
MAX_RADR_IDENTIFIER_DIGITS = 7
ALLOWED_ENDPOINT = "http:" + "//127." + "0.0.1:11434"

# This is a URI-scheme grammar, not a list of accepted protocols. A start is
# found in arbitrary binary data; the complete token is then bounded and
# parsed below. Delimiters are handled by the byte scanner so punctuation
# surrounding an exact token does not become authority text.
URI_START = re.compile(rb"(?<![A-Za-z0-9+.-])([A-Za-z][A-Za-z0-9+.-]*)://")
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*$")
INVALID_PERCENT = re.compile(r"%(?![0-9A-Fa-f]{2})")
ZONE_ID = re.compile(r"^[A-Za-z0-9_.~-]+$")
DNS_LABEL = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$")


class URIUnverifiable(Exception):
    """The token or helper input cannot be classified safely."""


class URIPrivate(Exception):
    """The token contains userinfo or a local/private authority."""


def _protocol(category: str, code: int) -> int:
    sys.stdout.write(category + "\n")
    return code


def _read_bounded(path: Path) -> bytes:
    try:
        if path.is_symlink() or not path.is_file():
            raise OSError
        metadata = path.stat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_INPUT_BYTES:
            raise URIUnverifiable
        with path.open("rb") as stream:
            data = stream.read(MAX_INPUT_BYTES + 1)
        if len(data) != metadata.st_size or len(data) > MAX_INPUT_BYTES:
            raise URIUnverifiable
        return data
    except URIUnverifiable:
        raise
    except (OSError, ValueError):
        raise OSError


def _is_token_delimiter(byte: int) -> bool:
    # Keep slash, question mark, hash, colon, at-sign, brackets, and percent
    # in the candidate: each can change URI semantics. Square brackets are
    # retained so a complete IPv6 authority reaches urlsplit/ipaddress.
    # RFC3986 sub-delimiters (including comma, semicolon, quote, parentheses,
    # and the other authority/path punctuation) remain in the candidate. The
    # only punctuation boundary accepted here is an unambiguous string/markup
    # delimiter that is not valid URI syntax.
    return byte <= 0x20 or byte == 0x7F or byte in b'"<>'


def _tokens(data: bytes):
    count = 0
    for match in URI_START.finditer(data):
        count += 1
        if count > MAX_URI_COUNT:
            raise URIUnverifiable
        scheme = match.group(1)
        if len(scheme) > MAX_SCHEME_LENGTH:
            raise URIUnverifiable

        end = match.end()
        while end < len(data):
            if _is_token_delimiter(data[end]):
                break
            end += 1
            if end - match.start() > MAX_TOKEN_BYTES:
                raise URIUnverifiable
        if end - match.start() > MAX_TOKEN_BYTES:
            raise URIUnverifiable

        raw = data[match.start() : end]
        try:
            token = raw.decode("utf-8")
        except UnicodeDecodeError:
            raise URIUnverifiable
        if token.count("://") != 1:
            raise URIUnverifiable
        yield token


def _percent_decode(value: str) -> str:
    if INVALID_PERCENT.search(value):
        raise URIUnverifiable
    try:
        decoded = unquote_to_bytes(value)
        if len(decoded) > MAX_TOKEN_BYTES:
            raise URIUnverifiable
        return decoded.decode("utf-8")
    except (UnicodeDecodeError, ValueError):
        raise URIUnverifiable


def _legacy_ipv4(host: str):
    """Parse bounded historical inet_aton IPv4 forms."""

    if not host:
        return None
    parts = host.split(".")
    all_decimal = all(char.isdigit() or char == "." for char in host)
    has_hex_component = any(part.lower().startswith("0x") for part in parts)
    if not all_decimal and not has_hex_component:
        return None
    if len(parts) > 4 or any(part == "" for part in parts):
        raise URIUnverifiable

    def component(part: str) -> int:
        lowered = part.lower()
        if lowered.startswith("0x"):
            digits = part[2:]
            if not digits or not re.fullmatch(r"[0-9A-Fa-f]+", digits):
                raise URIUnverifiable
            base = 16
        elif len(part) > 1 and part.startswith("0"):
            digits = part[1:]
            if not digits or not re.fullmatch(r"[0-7]+", digits):
                raise URIUnverifiable
            base = 8
        else:
            digits = part
            if not digits or not digits.isdigit():
                raise URIUnverifiable
            base = 10
        try:
            return int(digits, base)
        except (TypeError, ValueError, OverflowError):
            raise URIUnverifiable

    values = [component(part) for part in parts]
    limits = {
        1: (0xFFFFFFFF,),
        2: (0xFF, 0xFFFFFF),
        3: (0xFF, 0xFF, 0xFFFF),
        4: (0xFF, 0xFF, 0xFF, 0xFF),
    }
    if len(values) not in limits or any(
        value > limit for value, limit in zip(values, limits[len(values)])
    ):
        raise URIUnverifiable
    if len(values) == 1:
        number = values[0]
    elif len(values) == 2:
        number = (values[0] << 24) | values[1]
    elif len(values) == 3:
        number = (values[0] << 24) | (values[1] << 16) | values[2]
    else:
        number = (
            (values[0] << 24)
            | (values[1] << 16)
            | (values[2] << 8)
            | values[3]
        )
    try:
        return ipaddress.IPv4Address(number)
    except ValueError:
        raise URIUnverifiable


def _validate_dns_name(host_ascii: str) -> None:
    if len(host_ascii) > 253:
        raise URIUnverifiable
    labels = host_ascii.split(".")
    if any(
        not label or len(label) > 63 or not DNS_LABEL.fullmatch(label)
        for label in labels
    ):
        raise URIUnverifiable


def _unsafe_address(address: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    """Reject non-public-unicast address classes explicitly.

    ``is_global`` is runtime-version-sensitive and is not a sufficient
    inverse safety predicate: multicast and deprecated site-local ranges may
    otherwise be reported as global. Mapped IPv4 is classified recursively so
    mapped multicast/private/loopback values cannot bypass the IPv4 rules.
    """

    if (
        not address.is_global
        or address.is_private
        or address.is_loopback
        or address.is_link_local
        or address.is_unspecified
        or address.is_multicast
        or address.is_reserved
    ):
        return True
    if isinstance(address, ipaddress.IPv6Address):
        if address.is_site_local:
            return True
        mapped = address.ipv4_mapped
        if mapped is not None:
            return _unsafe_address(mapped)
    return False


def _classify_host(host_raw: str, bracketed: bool) -> bool:
    """Return True when the authority is local/private or scoped."""

    host = _percent_decode(host_raw)
    if not host:
        raise URIUnverifiable

    zone_present = False
    if "%" in host:
        if not bracketed:
            raise URIUnverifiable
        host, zone = host.split("%", 1)
        if not zone or not ZONE_ID.fullmatch(zone):
            raise URIUnverifiable
        zone_present = True

    if host.endswith("."):
        host = host[:-1]
    if not host or any(ord(char) < 0x21 or ord(char) == 0x7F for char in host):
        raise URIUnverifiable

    if ":" in host:
        if not bracketed or any(char in "[]/\\?#@" for char in host):
            raise URIUnverifiable
        try:
            address = ipaddress.IPv6Address(host)
        except ValueError:
            raise URIUnverifiable
        # A scope identifier is local-scope syntax even if the address text
        # happens to be globally routable; reject it conservatively.
        return zone_present or _unsafe_address(address)

    if bracketed or any(char in "[]/\\?#@" for char in host):
        raise URIUnverifiable
    try:
        host_ascii = host.encode("idna").decode("ascii").lower()
    except (UnicodeError, UnicodeEncodeError):
        raise URIUnverifiable

    if host_ascii.endswith("."):
        host_ascii = host_ascii[:-1]
    if not host_ascii:
        raise URIUnverifiable

    if (
        host_ascii == "localhost"
        or host_ascii.endswith(".localhost")
        or host_ascii == "localhost.localdomain"
        or host_ascii.endswith(".localhost.localdomain")
        or host_ascii.endswith(".local")
    ):
        return True

    # A dotted hostname beginning with a digit but containing non-numeric
    # components is ambiguous between legacy IPv4 and DNS; fail closed.
    if "." in host_ascii and host_ascii[0].isdigit() and not all(
        char.isdigit() or char == "." for char in host_ascii
    ):
        raise URIUnverifiable

    address = _legacy_ipv4(host_ascii)
    if address is not None:
        return _unsafe_address(address)

    try:
        address = ipaddress.ip_address(host_ascii)
    except ValueError:
        _validate_dns_name(host_ascii)
        # Do not resolve names: DNS would add mutable external behavior and
        # cannot prove that a public name will remain public.
        return False
    return _unsafe_address(address)


def _parse_token(token: str, allow_exact: bool) -> None:
    if allow_exact and token == ALLOWED_ENDPOINT:
        return
    if not token or INVALID_PERCENT.search(token):
        raise URIUnverifiable
    match = re.match(r"^([A-Za-z][A-Za-z0-9+.-]*)://", token)
    if not match or len(match.group(1)) > MAX_SCHEME_LENGTH:
        raise URIUnverifiable
    if not SCHEME.fullmatch(match.group(1)) or token.count("://") != 1:
        raise URIUnverifiable
    scheme = match.group(1).lower()
    # Mach-O diagnostics contain a short ``radr://<decimal-id>`` opaque
    # identifier. It is a non-network form, but decimal authorities overlap
    # legacy IPv4 integers. Keep the exception explicit to the main-binary
    # allow context and bounded to the observed seven-digit identifier form;
    # longer/private-looking values and every no-exception/resource context
    # use the normal fail-closed authority parser.
    radr_pattern = rf"radr://[0-9]{{{MAX_RADR_IDENTIFIER_DIGITS}}}"
    if allow_exact and scheme == "radr" and re.fullmatch(
        radr_pattern, token, re.IGNORECASE
    ):
        return
    try:
        parts = urlsplit(token)
    except (TypeError, ValueError):
        raise URIUnverifiable
    if not parts.scheme or not parts.netloc:
        raise URIUnverifiable

    netloc = parts.netloc
    if any(ord(char) <= 0x20 or ord(char) == 0x7F for char in netloc):
        raise URIUnverifiable
    if "\\" in netloc or netloc.count("@") > 1:
        raise URIUnverifiable

    userinfo_present = "@" in netloc
    if userinfo_present:
        userinfo, hostport = netloc.rsplit("@", 1)
        if not userinfo:
            raise URIUnverifiable
        _percent_decode(userinfo)
    else:
        hostport = netloc

    bracketed = hostport.startswith("[")
    if bracketed:
        closing = hostport.find("]")
        if closing < 0:
            raise URIUnverifiable
        host_raw = hostport[1:closing]
        remainder = hostport[closing + 1 :]
        if remainder and not remainder.startswith(":"):
            raise URIUnverifiable
        port_raw = remainder[1:] if remainder else None
    else:
        if "[" in hostport or "]" in hostport or hostport.count(":") > 1:
            raise URIUnverifiable
        if ":" in hostport:
            host_raw, port_raw = hostport.split(":", 1)
        else:
            host_raw, port_raw = hostport, None

    if port_raw is not None:
        if not port_raw or not re.fullmatch(r"[0-9]{1,5}", port_raw):
            raise URIUnverifiable
        try:
            if int(port_raw, 10) > 65535:
                raise URIUnverifiable
        except (TypeError, ValueError, OverflowError):
            raise URIUnverifiable

    private_host = _classify_host(host_raw, bracketed)
    if userinfo_present or private_host:
        raise URIPrivate


def classify(path: Path, allow_exact: bool) -> str:
    data = _read_bounded(path)
    private = False
    for token in _tokens(data):
        try:
            _parse_token(token, allow_exact)
        except URIPrivate:
            private = True
        except URIUnverifiable:
            raise
    return "PROHIBITED_PRIVATE_ENDPOINT" if private else "PASS"


def main(argv: list[str]) -> int:
    # The scanner must explicitly select the main-binary exception context;
    # path-only invocation is fail-closed and does not enable any exception.
    if len(argv) == 2:
        allow_exact = False
        path_arg = argv[1]
    elif len(argv) == 3 and argv[1] in {"--allow-exact", "--no-allow-exact"}:
        allow_exact = argv[1] == "--allow-exact"
        path_arg = argv[2]
    else:
        return 3
    if path_arg.startswith("-"):
        return 3
    try:
        result = classify(Path(path_arg), allow_exact)
    except URIUnverifiable:
        return _protocol("UNVERIFIABLE_SURFACE_URI", 2)
    except Exception:
        # Tool/input ambiguity is closed without a traceback or path leak.
        return 3
    return _protocol(result, 1 if result == "PROHIBITED_PRIVATE_ENDPOINT" else 0)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
