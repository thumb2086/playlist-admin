"""
File Renamer Utility
Renames music files based on their metadata to Artist - Title format
Supports batch processing of existing files
"""

import os
import re
from pathlib import Path
from mutagen.flac import FLAC
from mutagen.id3 import ID3
from mutagen.easyid3 import EasyID3
from mutagen.mp4 import MP4
from utils.helpers import sanitize_filename

class FileRenamer:
    """Utility to rename music files based on metadata"""
    
    def __init__(self, library_path: str, log_func=None):
        self.library_path = library_path
        self.log_func = log_func or self._default_log
        
    def _default_log(self, message: str):
        """Default logging function"""
        print(message)
    
    def extract_metadata(self, file_path: str) -> dict:
        """Extract metadata from audio file"""
        try:
            file_ext = Path(file_path).suffix.lower()
            metadata = {}
            
            if file_ext == '.flac':
                audio = FLAC(file_path)
                metadata = {
                    'title': audio.get('TITLE', [''])[0],
                    'artist': audio.get('ARTIST', [''])[0],
                    'album': audio.get('ALBUM', [''])[0],
                    'date': audio.get('DATE', [''])[0]
                }
            elif file_ext in ['.mp3', '.mp2', '.mp1']:
                try:
                    audio = EasyID3(file_path)
                    metadata = {
                        'title': audio.get('title', [''])[0],
                        'artist': audio.get('artist', [''])[0],
                        'album': audio.get('album', [''])[0],
                        'date': audio.get('date', [''])[0]
                    }
                except:
                    # Fallback to ID3 if EasyID3 fails
                    audio = ID3(file_path)
                    metadata = {
                        'title': '',
                        'artist': '',
                        'album': '',
                        'date': ''
                    }
                    # Extract from ID3 tags
                    if 'TIT2' in audio:
                        metadata['title'] = str(audio['TIT2'])
                    if 'TPE1' in audio:
                        metadata['artist'] = str(audio['TPE1'])
                    if 'TALB' in audio:
                        metadata['album'] = str(audio['TALB'])
                    if 'TDRC' in audio:
                        metadata['date'] = str(audio['TDRC'])
            elif file_ext in ['.m4a', '.mp4']:
                audio = MP4(file_path)
                metadata = {
                    'title': audio.get('\xa9nam', [''])[0],
                    'artist': audio.get('\xa9ART', [''])[0],
                    'album': audio.get('\xa9alb', [''])[0],
                    'date': audio.get('\xa9day', [''])[0]
                }
            else:
                self.log_func(f"  ⚠️ [Unsupported Format] {file_path}")
                return None
                
            return metadata
            
        except Exception as e:
            self.log_func(f"  ❌ [Metadata Error] {file_path}: {str(e)}")
            return None
    
    def generate_new_filename(self, metadata: dict, file_ext: str, original_filename: str = "") -> str:
        """Generate new filename based on metadata with Title-Artist format (no year)
        
        Args:
            metadata: Extracted metadata dict (title, artist, album, date)
            file_ext: File extension (e.g., '.m4a')
            original_filename: Original filename (without extension) as fallback
        """
        artist = metadata.get('artist', '').strip()
        title = metadata.get('title', '').strip()
        album = metadata.get('album', '').strip()

        # Build filename components
        name_parts = []

        # Priority order: Title - Artist (歌名-歌手格式, 與播放清單一致)
        if artist and title:
            base_name = f"{title} - {artist}"
        elif title:
            # 只有歌名，直接使用歌名
            base_name = title
        elif artist:
            # 只有歌手，使用歌手名
            base_name = artist
        elif album:
            # 只有專輯名，使用專輯名
            base_name = album
        elif original_filename:
            # 都沒有元數據，使用原始檔名作為後備
            base_name = original_filename
        else:
            # 都沒有，使用預設名稱
            base_name = "Unknown_Song"

        # Sanitize the filename
        safe_name = sanitize_filename(base_name)
        
        # Final safety check
        if not safe_name or safe_name.isspace():
            safe_name = "Unknown_Song"
        
        return f"{safe_name}{file_ext}"
    
    def rename_file(self, file_path: str, dry_run: bool = True) -> dict:
        """Rename a single file based on its metadata with improved error handling"""
        result = {
            'success': False,
            'old_path': file_path,
            'new_path': file_path,  # Default to original path
            'metadata': None,
            'message': ''
        }
        
        try:
            # Extract metadata
            metadata = self.extract_metadata(file_path)
            if not metadata:
                result['message'] = "Could not extract metadata"
                return result
            
            result['metadata'] = metadata
            
# Generate new filename with original filename as fallback
            file_ext = Path(file_path).suffix.lower()
            original_filename = Path(file_path).stem
            new_filename = self.generate_new_filename(metadata, file_ext, original_filename)

            if not new_filename:
                result['message'] = "Could not generate new filename"
                return result

            # No usable metadata → keep the original filename instead of "Unknown_Song".
            if new_filename.startswith("Unknown_Song"):
                result['success'] = True
                result['message'] = "No metadata to rename after; keeping original name"
                return result
            
            # Get new path
            new_path = Path(file_path).parent / new_filename
            
            # Check if new path is the same as old
            if new_path == Path(file_path):
                result['success'] = True
                result['message'] = "Filename already correct"
                return result
            
            # Check if new file already exists
            if new_path.exists() and new_path != Path(file_path):
                result['message'] = f"Target file already exists: {new_filename}"
                return result
            
            # Perform rename if not dry run
            if not dry_run:
                try:
                    import shutil
                    shutil.move(str(file_path), str(new_path))
                    result['new_path'] = str(new_path)
                    result['success'] = True
                    result['message'] = f"Successfully renamed to {new_filename}"
                except Exception as e:
                    result['message'] = f"Failed to rename file: {str(e)}"
                    return result
            else:
                # Dry run - just report what would happen
                result['new_path'] = str(new_path)
                result['success'] = True
                result['message'] = f"Would rename to {new_filename}"
            
        except Exception as e:
            result['message'] = f"Error during rename process: {str(e)}"
            result['success'] = False
        
        return result
    
    def scan_library(self, recursive: bool = True) -> list:
        """Scan library for audio files"""
        audio_extensions = {'.mp3', '.flac', '.m4a', '.mp4', '.mp2', '.mp1'}
        audio_files = []
        
        if recursive:
            for root, dirs, files in os.walk(self.library_path):
                for file in files:
                    if Path(file).suffix.lower() in audio_extensions:
                        audio_files.append(os.path.join(root, file))
        else:
            for file in os.listdir(self.library_path):
                file_path = os.path.join(self.library_path, file)
                if os.path.isfile(file_path) and Path(file).suffix.lower() in audio_extensions:
                    audio_files.append(file_path)
        
        return sorted(audio_files)
    
    def batch_rename(self, dry_run: bool = True, recursive: bool = True) -> dict:
        """Batch rename all files in library"""
        results = {
            'total_files': 0,
            'processed': 0,
            'renamed': 0,
            'errors': 0,
            'skipped': 0,
            'details': []
        }
        
        audio_files = self.scan_library(recursive)
        results['total_files'] = len(audio_files)
        
        self.log_func(f"🔍 [Scanning] Found {len(audio_files)} audio files")
        
        for i, file_path in enumerate(audio_files, 1):
            self.log_func(f"📁 [{i}/{len(audio_files)}] Processing: {os.path.basename(file_path)}")
            
            result = self.rename_file(file_path, dry_run)
            results['details'].append(result)
            results['processed'] += 1
            
            if result['success']:
                if result['new_path'] and result['new_path'] != file_path:
                    results['renamed'] += 1
                    self.log_func(f"  ✅ {result['message']}")
                else:
                    results['skipped'] += 1
                    self.log_func(f"  ℹ️ {result['message']}")
            else:
                results['errors'] += 1
                self.log_func(f"  ❌ {result['message']}")
        
        return results
    
    def preview_changes(self, recursive: bool = True, limit: int = 50) -> list:
        """Preview changes for first N files"""
        audio_files = self.scan_library(recursive)[:limit]
        preview = []
        
        for file_path in audio_files:
            metadata = self.extract_metadata(file_path)
            if metadata:
                file_ext = Path(file_path).suffix.lower()
                original_filename = Path(file_path).stem
                new_filename = self.generate_new_filename(metadata, file_ext, original_filename)
                
                if new_filename and new_filename != os.path.basename(file_path):
                    preview.append({
                        'old_name': os.path.basename(file_path),
                        'new_name': new_filename,
                        'artist': metadata.get('artist', 'Unknown'),
                        'title': metadata.get('title', 'Unknown'),
                        'path': file_path
                    })
        
        return preview

def create_file_renamer(library_path: str, log_func=None) -> FileRenamer:
    """Factory function to create FileRenamer instance"""
    return FileRenamer(library_path, log_func)
