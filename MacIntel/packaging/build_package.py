#!/usr/bin/env python3
"""Rebuild the autonomous Mac Intel ZIP from the verified V2.12.18 package."""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

VERSION='2.12.19'
MINIMUM_MACOS=(11,0,0)
MINIMUM_MACOS_TEXT='11.0'
TEMP_OUTPUT=None
BASE_SHA256='ee7f04167ef2bec5bd2eea15db23d16e109abe133ab32b7c79e2a33774286acf'
EXPECTED={
 'AnalizadorMultitracksV2.command':'e60b0d20f83d9d7dc0e646d83e67237ce04cae54c020e960f8958dc18eee195c',
 'GeneradorPDFMacIntel':'7cc720272d5749a77454d497d45a893ec93ed7284c6039690fb6d28faf01d0b7',
 'EffectiveDepth.pl':'ac4402c06fc1d2ad2c033522439096ae04608d78422f95625465d0b34759b320',
 'ffmpeg':'e27de05e3a9f9c758f9766d15d1a069fddeed5f725e35d9ab28683be4740dad7',
 'ffprobe':'a1508faa028bfb8e20c9d182c3d41fcff29ee7584ae21b2d6c357472a3ecbc24',
 'Progress.applescript':'0f448b3d27fee8e7a995fde6a1d07b0bd837f12c470127e9e386880ccffe92ab',
 'AppIcon.icns':'fa1dd038f248388ad30c368c21e159e6461c054d00d7a380256a32eb966f0540',
 'LICENCIA_FUENTE_DEJAVU.txt':'e180b3d65bf650dffffd71dd21b6180767b469a18dd87e1d8552be69bb9ecdf0',
 'DejaVuSans.ttf':'ae7b7855e115a5966d8b1b3f80f254ccc117ec86f9965e202ee2940453837280',
 'DejaVuSans-Bold.ttf':'5c1247acef7f2b8522a31742c76d6adcb5569bacc0be7ceaa4dc39dd252ce895',
}
EXPECTED_INFO='b337b15771ba8c59d01e47341aedf5f35ee48385c6bf54dec3dc16755e53d403'
EXPECTED_LAUNCHER='41fc269df94e10b684c26663b92c71116e5a3cc5e1d3929b85bd4c2700754449'
EXPECTED_GUIDES={
 '01 Cómo abrir.pdf':'b67b4045327c90f3d6cfc3788df77eba0af38c16fb88c4ac7ab660197daa6518',
 '02 Qué hace y cómo trabaja.pdf':'480292c4e8e0e10dd01e81cec265204704bb18cda16e9f31cfc952a6c8d3e04a',
}
OLD_ROOT='Analizador de Multitracks Estudio PG V2.12.18 (Mac Intel)/'
NEW_ROOT='Analizador de Multitracks Estudio PG V2.12.19 (Mac Intel)/'
OLD_APP=OLD_ROOT+'Analizador de Multitracks Estudio PG V2.12.18 (Mac Intel).app/'
NEW_APP=NEW_ROOT+'Analizador de Multitracks Estudio PG V2.12.19 (Mac Intel).app/'


def sha256_stream(stream):
    h=hashlib.sha256()
    for block in iter(lambda:stream.read(1024*1024),b''): h.update(block)
    return h.hexdigest()

def sha256_file(path):
    with Path(path).open('rb') as f: return sha256_stream(f)

def canonical_name(info):
    name=info.filename
    if info.flag_bits & 0x800: return name
    try: return name.encode('cp437').decode('utf-8')
    except UnicodeDecodeError: return name

def has_x86_64_macho(data):
    if data[:4] in (b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf'):
        endian='<' if data[:4]==b'\xcf\xfa\xed\xfe' else '>'
        return struct.unpack(endian+'I',data[4:8])[0]==0x01000007
    if data[:4] in (b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf'):
        is64=data[:4]==b'\xca\xfe\xba\xbf'
        n=struct.unpack('>I',data[4:8])[0]
        width=32 if is64 else 20
        for i in range(n):
            off=8+i*width
            if struct.unpack('>I',data[off:off+4])[0]==0x01000007: return True
    return False

def x86_64_macho_slice(data):
    if data[:4] in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf'):
        endian='<' if data[:4]==b'\xcf\xfa\xed\xfe' else '>'
        if struct.unpack_from(endian+'I',data,4)[0]==0x01000007: return data
        raise ValueError('Thin Mach-O does not contain x86_64')
    if data[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        is64=data[:4]==b'\xca\xfe\xba\xbf'; n=struct.unpack_from('>I',data,4)[0]; width=32 if is64 else 20
        for i in range(n):
            off=8+i*width; cpu=struct.unpack_from('>I',data,off)[0]
            if cpu==0x01000007:
                if is64: start,size=struct.unpack_from('>QQ',data,off+8)
                else: start,size=struct.unpack_from('>II',data,off+8)
                return data[start:start+size]
    raise ValueError('No x86_64 Mach-O slice found')

def macho_minimum_macos(data):
    data=x86_64_macho_slice(data); endian='<' if data[:4]==b'\xcf\xfa\xed\xfe' else '>'
    ncmds=struct.unpack_from(endian+'I',data,16)[0]; off=32
    for _ in range(ncmds):
        cmd,size=struct.unpack_from(endian+'II',data,off)
        if cmd==0x32:
            _,_,platform,minos,_,_=struct.unpack_from(endian+'6I',data,off)
            if platform==1: return (minos>>16,(minos>>8)&255,minos&255)
        elif cmd==0x24:
            _,_,version,_=struct.unpack_from(endian+'4I',data,off)
            return (version>>16,(version>>8)&255,version&255)
        off+=size
    raise ValueError('No macOS minimum-version load command found')

def release_name(old_name):
    name=old_name.replace(OLD_ROOT,NEW_ROOT,1)
    old_app_leaf='Analizador de Multitracks Estudio PG V2.12.18 (Mac Intel).app/'
    new_app_leaf='Analizador de Multitracks Estudio PG V2.12.19 (Mac Intel).app/'
    return name.replace(old_app_leaf,new_app_leaf,1)

def zip_member_by_name(z,expected_name):
    matches=[i for i in z.infolist() if canonical_name(i)==expected_name]
    if len(matches)!=1: raise ValueError(f'Expected one ZIP entry {expected_name!r}, found {len(matches)}')
    return matches[0]

def verify_base(base):
    digest=sha256_file(base)
    if digest.lower()!=BASE_SHA256: raise ValueError(f'Base ZIP SHA-256 mismatch: {digest}')
    with zipfile.ZipFile(base) as z:
        for component,expected in EXPECTED.items():
            entry=zip_member_by_name(z,OLD_APP+f'Contents/Resources/{component}')
            with z.open(entry) as f: actual=sha256_stream(f)
            if actual!=expected: raise ValueError(f'{component} SHA-256 mismatch: {actual}')
        plist=zip_member_by_name(z,OLD_APP+'Contents/Info.plist')
        plist_bytes=z.read(plist)
        if hashlib.sha256(plist_bytes).hexdigest()!=EXPECTED_INFO: raise ValueError('Info.plist SHA-256 mismatch')
        info=plistlib.loads(plist_bytes)
        launcher=zip_member_by_name(z,OLD_APP+'Contents/MacOS/AnalizadorMultitracks')
        with z.open(launcher) as f: launcher_hash=sha256_stream(f)
        if launcher_hash!=EXPECTED_LAUNCHER: raise ValueError('Mac launcher SHA-256 mismatch')
        for name,expected in EXPECTED_GUIDES.items():
            entry=zip_member_by_name(z,OLD_ROOT+name)
            with z.open(entry) as f: actual=sha256_stream(f)
            if actual!=expected: raise ValueError(f'Reference guide SHA-256 mismatch: {name}')
        if info.get('CFBundleShortVersionString')!='2.12.18': raise ValueError('The input app is not V2.12.18')
        minimums={}
        for name in ('GeneradorPDFMacIntel','ffmpeg','ffprobe'):
            entry=zip_member_by_name(z,OLD_APP+f'Contents/Resources/{name}')
            data=z.read(entry)
            if not has_x86_64_macho(data): raise ValueError(f'{name} is not x86_64 Mach-O')
            minimums[name]=macho_minimum_macos(data)
        if minimums['GeneradorPDFMacIntel']!=(11,0,0): raise ValueError(f'Unexpected PDF generator macOS minimum: {minimums["GeneradorPDFMacIntel"]}')
        if any(version>MINIMUM_MACOS for version in minimums.values()): raise ValueError(f'A bundled binary requires macOS newer than {MINIMUM_MACOS_TEXT}: {minimums}')
    return digest

def main():
    global TEMP_OUTPUT
    parser=argparse.ArgumentParser()
    parser.add_argument('--base-package',required=True,type=Path)
    parser.add_argument('--output',type=Path,default=Path(__file__).resolve().parents[1]/'dist'/'Analizador de Multitracks Estudio PG V2.12.19 (Mac Intel).zip')
    args=parser.parse_args()
    base=args.base_package.expanduser().resolve()
    output=args.output.expanduser().resolve()
    if not base.is_file(): raise FileNotFoundError(f'Base package not found: {base}')
    if output.exists(): raise FileExistsError(f'Output already exists; move it aside or select another --output: {output}')
    root=Path(__file__).resolve().parents[1]
    app=root/'app'/'Contents'
    local={
      OLD_APP+'Contents/MacOS/AnalizadorMultitracks':app/'MacOS'/'AnalizadorMultitracks',
      OLD_APP+'Contents/Info.plist':app/'Info.plist',
      OLD_APP+'Contents/Resources/AnalizadorMultitracksV2.command':app/'Resources'/'AnalizadorMultitracksV2.command',
      OLD_APP+'Contents/Resources/EffectiveDepth.pl':app/'Resources'/'EffectiveDepth.pl',
      OLD_APP+'Contents/Resources/Progress.applescript':app/'Resources'/'Progress.applescript',
      OLD_APP+'Contents/Resources/GeneradorPDFMacIntel':app/'Resources'/'GeneradorPDFMacIntel',
      OLD_APP+'Contents/Resources/DejaVuSans.ttf':app/'Resources'/'DejaVuSans.ttf',
      OLD_APP+'Contents/Resources/DejaVuSans-Bold.ttf':app/'Resources'/'DejaVuSans-Bold.ttf',
      OLD_APP+'Contents/Resources/AppIcon.icns':app/'Resources'/'AppIcon.icns',
      OLD_APP+'Contents/Resources/LICENCIA_FUENTE_DEJAVU.txt':app/'Resources'/'LICENCIA_FUENTE_DEJAVU.txt',
      OLD_ROOT+'01 Cómo abrir.pdf':root/'docs'/'01 Cómo abrir.pdf',
      OLD_ROOT+'02 Qué hace y cómo trabaja.pdf':root/'docs'/'02 Qué hace y cómo trabaja.pdf',
    }
    for archive_name,path in local.items():
        if not path.is_file(): raise FileNotFoundError(f'Required source file missing: {path}')
    # Small pinned resources recovered from the package must remain byte-identical.
    with zipfile.ZipFile(base) as z:
        for name in ('EffectiveDepth.pl','GeneradorPDFMacIntel','DejaVuSans.ttf','DejaVuSans-Bold.ttf','AppIcon.icns','LICENCIA_FUENTE_DEJAVU.txt'):
            entry=zip_member_by_name(z,OLD_APP+f'Contents/Resources/{name}')
            source=app/'Resources'/name
            with z.open(entry) as f: original=sha256_stream(f)
            if sha256_file(source)!=original: raise ValueError(f'Unexpected modification to pinned component: {name}')
        for name,expected in (('ffmpeg',EXPECTED['ffmpeg']),('ffprobe',EXPECTED['ffprobe'])):
            entry=zip_member_by_name(z,OLD_APP+f'Contents/Resources/{name}')
            with z.open(entry) as f: actual=sha256_stream(f)
            if actual!=expected: raise ValueError(f'{name} changed in base package')
        launcher_name=OLD_APP+'Contents/MacOS/AnalizadorMultitracks'
        entry=zip_member_by_name(z,launcher_name)
        original_launcher=z.read(entry)
        expected_launcher=original_launcher.replace(b'V2.12.18',b'V2.12.19').replace(b'No se pudieron generar los PDF.',b'No se pudieron generar o publicar los PDF.')
        if local[launcher_name].read_bytes()!=expected_launcher: raise ValueError('Launcher contains changes beyond the release label and PDF error message')
        progress_name=OLD_APP+'Contents/Resources/Progress.applescript'
        original_progress=z.read(zip_member_by_name(z,progress_name)).decode('utf-8')
        expected_progress=original_progress.replace('set progress description to "Analizador de Multitracks Estudio PG V2.12.18"','set progress description to "Analizador de Multitracks Estudio PG V2.12.19"').replace('set currentPhase to "Analizador de Multitracks Estudio PG V2.12.18"','set currentPhase to "Analizador de Multitracks Estudio PG V2.12.19"')
        if local[progress_name].read_text(encoding='utf-8')!=expected_progress: raise ValueError('Progress script changed beyond the release label')

    plist_data=(app/'Info.plist').read_bytes()
    plist=plistlib.loads(plist_data)
    if plist.get('CFBundleShortVersionString')!=VERSION or plist.get('CFBundleVersion')!=VERSION: raise ValueError('Info.plist version is not V2.12.19')
    if plist.get('LSMinimumSystemVersion')!=MINIMUM_MACOS_TEXT: raise ValueError('Info.plist minimum macOS version must be 11.0')

    # Build a machine-readable component manifest from the exact package inputs.
    base_sha=verify_base(base)
    subprocess.run([sys.executable,str(root/'packaging'/'generate_guides.py')],check=True)
    components={}
    for archive_name,path in sorted(local.items()):
        components[release_name(archive_name).removeprefix(NEW_ROOT)]=sha256_file(path)
    with zipfile.ZipFile(base) as z:
        for name in ('ffmpeg','ffprobe'):
            entry=zip_member_by_name(z,OLD_APP+f'Contents/Resources/{name}')
            with z.open(entry) as f: components[NEW_APP.removeprefix(NEW_ROOT)+'Contents/Resources/'+name]=sha256_stream(f)
    components[NEW_APP.removeprefix(NEW_ROOT)+'Contents/Resources/PublishPDFReports.sh']=sha256_file(app/'Resources'/'PublishPDFReports.sh')
    manifest={
      'application':'Analizador de Multitracks Estudio PG',
      'version':VERSION,
      'platform':'macOS Intel x86_64',
      'minimum_macos':MINIMUM_MACOS_TEXT,
      'base_package':{'filename':'Analizador de Multitracks Estudio PG V2.12.18 (Mac Intel).zip','sha256':base_sha},
      'pdf_generator_source':'not available; pinned compiled x86_64 binary',
      'components':components,
    }
    manifest_path=root/'manifest.json'
    manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
    manifest_bytes=manifest_path.read_bytes()

    output.parent.mkdir(parents=True,exist_ok=True)
    temporary=output.with_name(f'.{output.stem}.{os.getpid()}.tmp.zip')
    if temporary.exists(): raise FileExistsError(f'Temporary package path already exists: {temporary}')
    TEMP_OUTPUT=temporary
    helper_name=NEW_APP+'Contents/Resources/PublishPDFReports.sh'
    helper_path=app/'Resources'/'PublishPDFReports.sh'
    with zipfile.ZipFile(base) as zin, zipfile.ZipFile(temporary,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6,allowZip64=True) as zout:
        seen=set()
        for info in zin.infolist():
            old_name=canonical_name(info)
            new_name=release_name(old_name)
            if new_name in seen: raise ValueError(f'Duplicate output ZIP entry: {new_name}')
            seen.add(new_name)
            new_info=copy.copy(info)
            new_info.filename=new_name; new_info.orig_filename=new_name
            if not info.is_dir() and old_name in local:
                data=local[old_name].read_bytes()
                zout.writestr(new_info,data)
            else:
                with zin.open(info) as src, zout.open(new_info,'w') as dst:
                    shutil.copyfileobj(src,dst,1024*1024)
        # Add the helper and an in-package integrity manifest. Both are UTF-8 names.
        helper_info=zipfile.ZipInfo(helper_name)
        helper_info.compress_type=zipfile.ZIP_DEFLATED; helper_info.create_system=3; helper_info.external_attr=(0o100755<<16)
        zout.writestr(helper_info,helper_path.read_bytes())
        manifest_info=zipfile.ZipInfo(NEW_ROOT+'MANIFEST.json')
        manifest_info.compress_type=zipfile.ZIP_DEFLATED; manifest_info.create_system=3; manifest_info.external_attr=(0o100644<<16)
        zout.writestr(manifest_info,manifest_bytes)
    # Verify the complete archive and all expected Intel executables before delivering it.
    with zipfile.ZipFile(temporary) as z:
        bad=z.testzip()
        if bad: raise ValueError(f'Corrupt ZIP member: {bad}')
        for name in (
          NEW_APP+'Contents/Resources/GeneradorPDFMacIntel',
          NEW_APP+'Contents/Resources/ffmpeg',
          NEW_APP+'Contents/Resources/ffprobe',
        ):
            entry=zip_member_by_name(z,name)
            with z.open(entry) as f: data=f.read(16*1024*1024)
            if not has_x86_64_macho(data): raise ValueError(f'Not a recognized x86_64 Mach-O binary: {name}')
            minimum=macho_minimum_macos(data)
            if minimum>MINIMUM_MACOS: raise ValueError(f'{name} requires macOS {minimum}, newer than declared {MINIMUM_MACOS_TEXT}')
            if name=='GeneradorPDFMacIntel' and minimum!=(11,0,0): raise ValueError(f'Unexpected PDF generator macOS minimum: {minimum}')
        for name in (NEW_APP+'Contents/MacOS/AnalizadorMultitracks',NEW_APP+'Contents/Resources/AnalizadorMultitracksV2.command',helper_name,NEW_APP+'Contents/Resources/ffmpeg',NEW_APP+'Contents/Resources/ffprobe'):
            entry=zip_member_by_name(z,name)
            mode=(entry.external_attr>>16)&0o777
            if not mode&0o111: raise ValueError(f'Executable permission missing in ZIP: {name}')
    digest=sha256_file(temporary)
    temporary.replace(output)
    TEMP_OUTPUT=None
    checksum=output.with_suffix(output.suffix+'.sha256')
    checksum.write_text(f'{digest}  {output.name}\n',encoding='ascii',newline='\n')
    print(f'Created and verified {output}')
    print(f'SHA-256: {digest}')
    print(f'Package bytes: {output.stat().st_size}')

if __name__=='__main__':
    try: main()
    except Exception as exc:
        if TEMP_OUTPUT is not None and TEMP_OUTPUT.exists(): TEMP_OUTPUT.unlink()
        print(f'ERROR: {exc}',file=sys.stderr)
        raise
