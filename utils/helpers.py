import re
from zhconv import convert

# Windows forbidden characters (same across all sanitizers)
_WIN_FORBIDDEN_RE = re.compile(r'[<>:"/\\|?*]')

def sanitize_filename(name: str, *, fallback: str = "Unknown") -> str:
    """Sanitize string to be a valid Windows filename.
    
    Preserves all Unicode characters (including Japanese, Korean, Chinese)
    while replacing only Windows-forbidden characters.
    
    Args:
        name: Input string to sanitize
        fallback: Fallback name if result is empty
        
    Returns:
        Sanitized filename safe for Windows
    """
    if not name:
        return fallback
    
    # Remove non-breaking spaces and zero-width spaces
    name = name.replace('\xa0', ' ').replace('\u200b', '').strip()
    
    # Remove only truly unnecessary publisher/label garbage
    patterns_to_remove = [
        # Publisher prefixes at start: "Sony Music - " (ASCII only)
        r'^[A-Za-z0-9\s&]+ - (?=[^\-])',
        # Generic video suffixes (exact matches only)
        r'\s*Official\s+Video\s*$',
        r'\s*Music\s+Video\s*$',
        r'\s*MV\s*$',
        r'\s*官方.*?MV\s*$',
        r'\s*Lyrics?\s+Video\s*$',
        r'\s*動態歌詞版\s*$',
        r'\s*歌詞版\s*$',
        r'\s*發行.*?版\s*$',
        r'\s*\(Official\)\s*$',
        r'\s*\[Official\]\s*$',
    ]
    
    for pattern in patterns_to_remove:
        name = re.sub(pattern, '', name, flags=re.IGNORECASE)
    
    # Replace ONLY Windows-forbidden characters with underscore
    # Preserve ALL Unicode characters (Japanese, Korean, Chinese, emojis, etc.)
    name = _WIN_FORBIDDEN_RE.sub('_', name)
    
    # Clean up trailing/leading dots, spaces, hyphens
    name = name.strip('. -')
    
    # Collapse whitespace, normalize hyphens
    name = re.sub(r'\s+', ' ', name).strip()
    name = re.sub(r'-+', '-', name).strip()
    
    # Fallback if empty
    if not name or name.isspace():
        # Use original name with only forbidden chars replaced
        fallback_name = _WIN_FORBIDDEN_RE.sub('_', name if name else fallback)
        fallback_name = fallback_name.strip('. -')
        name = fallback_name[:200] if fallback_name else fallback
    
    return name[:200]


def sanitize_filename_strict(name: str) -> str:
    """Stricter sanitization: also replaces spaces and some punctuation.
    Used for cache keys where stricter normalization is needed."""
    if not name:
        return "unknown"
    name = name.replace('\xa0', ' ').replace('\u200b', '').strip()
    name = _WIN_FORBIDDEN_RE.sub('_', name)
    name = re.sub(r'[\s\-&]+', '_', name)  # spaces, hyphens, ampersands -> underscore
    name = re.sub(r'_+', '_', name).strip('_')
    return name[:100].lower() if name else "unknown"


def normalize_name(name: str) -> str:
    """Normalize string for fuzzy matching comparison (not for filenames).
    Converts to Simplified Chinese, removes brackets/punctuation/spaces."""
    if not name:
        return ""
    # Convert to Simplified Chinese for consistent comparison
    name = convert(name, 'zh-cn')
    # Replace brackets with space
    name = re.sub(r"[\(\[【\)\]】]", " ", name)
    # Remove all punctuation, spaces, underscores, hyphens
    name = re.sub(r'[\s_\-\.\,\;\:\!\?\'\"]+', '', name)
    return name.lower().strip()

def normalize_name(name):
    """Normalize string for fuzzy matching comparison"""
    # 1. Convert to Simplified Chinese (for consistent comparison)
    name = convert(name, 'zh-cn')
    # 2. Replace brackets with space.
    name = re.sub(r"[\(\[【\)\]】]", " ", name)
    # 3. Clean up
    return name.lower().strip().replace('_', ' ').replace('-', ' ').replace(' ', '')
def download_image(url, timeout=10):
    """Download image data from a URL"""
    if not url:
        return None
    try:
        import requests
        import urllib3
        # Disable SSL warnings for cases where certs might be an issue (like DAB sometimes)
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
        
        response = requests.get(url, timeout=timeout, verify=False)
        if response.status_code == 200:
            return response.content
    except Exception:
        pass
    return None


def encode_uri_path(path):
    """
    DEPRECATED: URI encoding is no longer used for M3U8 files.
    
    Windows players and Echo Nightly on mobile require raw file paths
    with forward slashes, not URL-encoded paths.
    
    Kept for potential future use but currently unused in playlist generation.
    """
    import warnings
    warnings.warn("encode_uri_path is deprecated, use raw paths with forward slashes", DeprecationWarning)
    import urllib.parse
    
    # Split by forward slash to preserve path structure
    parts = path.split('/')
    
    # Encode each path component separately
    encoded_parts = []
    for part in parts:
        # Use urllib.parse.quote for URI encoding
        # safe='' means encode everything including spaces
        encoded = urllib.parse.quote(part, safe='')
        encoded_parts.append(encoded)
    
    # Rejoin with forward slashes
    return '/'.join(encoded_parts)
