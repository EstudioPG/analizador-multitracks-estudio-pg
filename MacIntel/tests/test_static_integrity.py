#!/usr/bin/env python3
from __future__ import annotations
import argparse
import hashlib
import json
import plistlib
import re
import struct
import zipfile
from pathlib import Path
import pdfplumber

ROOT=Path(__file__).resolve().parents[1]
BASE_SHA='ee7f04167ef2bec5bd2eea15db23d16e109abe133ab32b7c79e2a33774286acf'
OLD_ROOT='Analizador de Multitracks Estudio PG V2.12.18 (Mac Intel)/'
OLD_APP=OLD_ROOT+'Analizador de Multitracks Estudio PG V2.12.18 (Mac Intel).app/'
NEW_ROOT='Analizador de Multitracks Estudio PG V2.12.19 (Mac Intel)/'
NEW_APP=NEW_ROOT+'Analizador de Multitracks Estudio PG V2.12.19 (Mac Intel).app/'
EXPECTED={
 'AnalizadorMultitracksV2.command':'e60b0d20f83d9d7dc0e646d83e67237ce04cae54c020e960f8958dc18eee195c',
 'GeneradorPDFMacIntel':'7cc720272d5749a77454d497d45a893ec93ed7284c6039690fb6d28faf01d0b7',
 'EffectiveDepth.pl':'ac4402c06fc1d2ad2c033522439096ae04608d78422f95625465d0b34759b320',
 'ffmpeg':'e27de05e3a9f9c758f9766d15d1a069fddeed5f725e35d9ab28683be4740dad7',
 'ffprobe':'a1508faa028bfb8e20c9d182c3d41fcff29ee7584ae21b2d6c357472a3ecbc24',
 'DejaVuSans.ttf':'ae7b7855e115a5966d8b1b3f80f254ccc117ec86f9965e202ee2940453837280',
 'DejaVuSans-Bold.ttf':'5c1247acef7f2b8522a31742c76d6adcb5569bacc0be7ceaa4dc39dd252ce895',
 'AppIcon.icns':'fa1dd038f248388ad30c368c21e159e6461c054d00d7a380256a32eb966f0540',
 'LICENCIA_FUENTE_DEJAVU.txt':'e180b3d65bf650dffffd71dd21b6180767b469a18dd87e1d8552be69bb9ecdf0',
}
EXPECTED_INFO='b337b15771ba8c59d01e47341aedf5f35ee48385c6bf54dec3dc16755e53d403'
EXPECTED_LAUNCHER='41fc269df94e10b684c26663b92c71116e5a3cc5e1d3929b85bd4c2700754449'
EXPECTED_GUIDES={'01 Cómo abrir.pdf':'b67b4045327c90f3d6cfc3788df77eba0af38c16fb88c4ac7ab660197daa6518','02 Qué hace y cómo trabaja.pdf':'480292c4e8e0e10dd01e81cec265204704bb18cda16e9f31cfc952a6c8d3e04a'}

def sha(data): return hashlib.sha256(data).hexdigest()
def sha_file(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
    return h.hexdigest()
def canonical(info):
    if info.flag_bits & 0x800: return info.filename
    try: return info.filename.encode('cp437').decode('utf-8')
    except UnicodeDecodeError: return info.filename
def member(z,name):
    found=[i for i in z.infolist() if canonical(i)==name]
    assert len(found)==1,(name,len(found))
    return z.read(found[0])
def mask(text,start,end,replacement):
    a=text.index(start); b=text.index(end,a)
    return text[:a]+replacement+text[b:]
def normalize_audio_source(text):
    text=text.replace('\r\n','\n')
    text=text.replace('PDF_PUBLISH_HELPER="$SCRIPT_DIR/PublishPDFReports.sh"\n','')
    text=text.replace('# ANALIZADOR DE MULTITRACKS ESTUDIO PG V2.12.19 - macOS INTEL','# ANALIZADOR DE MULTITRACKS ESTUDIO PG V2.12.18 - macOS INTEL')
    text=mask(text,'# INFORMES BÁSICO, DETALLADO Y TÉCNICO DE DESARROLLO','# INFORMES PDF PARA USUARIO','@@AUTHORIZED_REPORTS@@\n')
    text=mask(text,'# INFORMES PDF PARA USUARIO','PROFILE_PDF_T1=$(now_ms)','@@AUTHORIZED_PDF_PUBLICATION@@\n')
    text=text.replace('echo "ANALIZADOR DE MULTITRACKS ESTUDIO PG — V2.12.19 (Mac Intel)"','echo "ANALIZADOR DE MULTITRACKS ESTUDIO PG — V2.12.18 (Mac Intel)"')
    text=text.replace('Algoritmo ETA V2.12.19:','Algoritmo ETA V2.12.18:')
    text=text.replace('Progreso V2.12.19:','Progreso V2.12.18:')
    return text

def has_x86_64(data):
    if data[:4] in (b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf'):
        endian='<' if data[:4]==b'\xcf\xfa\xed\xfe' else '>'
        return struct.unpack(endian+'I',data[4:8])[0]==0x01000007
    if data[:4] in (b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf'):
        width=32 if data[:4]==b'\xca\xfe\xba\xbf' else 20
        n=struct.unpack('>I',data[4:8])[0]
        return any(struct.unpack('>I',data[8+i*width:12+i*width])[0]==0x01000007 for i in range(n))
    return False

def verify_source(base):
    assert sha_file(base)==BASE_SHA,'base ZIP hash mismatch'
    with zipfile.ZipFile(base) as z:
        old_shell=member(z,OLD_APP+'Contents/Resources/AnalizadorMultitracksV2.command').decode('utf-8')
        old_launcher=member(z,OLD_APP+'Contents/MacOS/AnalizadorMultitracks').decode('utf-8')
        old_progress=member(z,OLD_APP+'Contents/Resources/Progress.applescript').decode('utf-8')
        old_plist_bytes=member(z,OLD_APP+'Contents/Info.plist')
        old_plist=old_plist_bytes.decode('utf-8')
        assert sha(old_plist_bytes)==EXPECTED_INFO,'base Info.plist hash differs'
        assert sha(member(z,OLD_APP+'Contents/MacOS/AnalizadorMultitracks'))==EXPECTED_LAUNCHER,'base launcher hash differs'
        assert sha(member(z,OLD_APP+'Contents/Resources/Progress.applescript'))=='0f448b3d27fee8e7a995fde6a1d07b0bd837f12c470127e9e386880ccffe92ab','base progress script hash differs'
        for guide,expected in EXPECTED_GUIDES.items(): assert sha(member(z,OLD_ROOT+guide))==expected,f'base guide hash differs: {guide}'
        for name,expected in EXPECTED.items():
            baseline=member(z,OLD_APP+'Contents/Resources/'+name)
            assert sha(baseline)==expected,f'{name} hash in the base ZIP differs from the recorded baseline'
            if name not in ('ffmpeg','ffprobe','AnalizadorMultitracksV2.command'):
                data=(ROOT/'app'/'Contents'/'Resources'/name).read_bytes()
                assert sha(data)==expected,f'unchanged Mac resource altered: {name}'
                assert data==baseline,f'{name} differs from V2.12.18 source'
        current=(ROOT/'app'/'Contents'/'Resources'/'AnalizadorMultitracksV2.command').read_text(encoding='utf-8')
        assert normalize_audio_source(current)==normalize_audio_source(old_shell),'code outside the authorized report/PDF areas changed'
        assert len(re.findall(r'^DUPLICATE_ANALYSIS_ENABLED=0$',current,re.M))==1,'duplicate comparison is not pinned disabled'
        assert len(re.findall(r'^DUPLICATE_ANALYSIS_ENABLED=',current,re.M))==1,'duplicate flag has another assignment'
        basic=current.split('# -------------------- INFORME BÁSICO -------------------------',1)[1].split('# ------------------- INFORME DETALLADO -----------------------',1)[0]
        detail=current.split('# ------------------- INFORME DETALLADO -----------------------',1)[1].split('PROFILE_REPORT_T1=$(now_ms)',1)[0]
        for label,report in [('basic',basic),('detail',detail)]:
            assert not re.search(r'duplicad|fingerprint|hash',report,re.I),f'user {label} report mentions disabled duplicate analysis'
        assert 'RESUMEN OPERATIVO' not in basic,'redundant basic summary returned'
        assert 'RESUMEN TÉCNICO' not in detail,'redundant detailed summary returned'
        tech=current.split('INFORME TÉCNICO / DESARROLLO',1)[1].split('REPORT="$REPORT_DETAIL"',1)[0]
        for item in ('Comparación de duplicados: TEMPORALMENTE DESACTIVADA','Hashes para duplicados: 0','Fingerprints calculados: 0','Filtros de elegibilidad ejecutados: 0','Comparaciones de señal entre archivos: 0','Grupos de duplicados: NO EVALUADO','TIEMPO TOTAL','MUESTRAS ETA'):
            assert item in tech,f'technical metrics/state missing: {item}'
        launcher=(ROOT/'app'/'Contents'/'MacOS'/'AnalizadorMultitracks').read_text(encoding='utf-8')
        expected_launcher=old_launcher.replace('V2.12.18','V2.12.19').replace('No se pudieron generar los PDF.','No se pudieron generar o publicar los PDF.')
        assert launcher==expected_launcher,'launcher changed beyond the version label and PDF error wording'
        progress=(ROOT/'app'/'Contents'/'Resources'/'Progress.applescript').read_text(encoding='utf-8')
        expected_progress=old_progress.replace('set progress description to "Analizador de Multitracks Estudio PG V2.12.18"','set progress description to "Analizador de Multitracks Estudio PG V2.12.19"').replace('set currentPhase to "Analizador de Multitracks Estudio PG V2.12.18"','set currentPhase to "Analizador de Multitracks Estudio PG V2.12.19"')
        assert progress==expected_progress,'progress behavior changed beyond version labels'
        plist=(ROOT/'app'/'Contents'/'Info.plist').read_text(encoding='utf-8')
        expected_plist=old_plist.replace('Analizador de Multitracks Estudio PG V2.12.18 (Mac Intel)','Analizador de Multitracks Estudio PG V2.12.19 (Mac Intel)').replace('<string>2.12.18</string>','<string>2.12.19</string>')
        assert plist==expected_plist,'Info.plist changed beyond the release version'
        assert plistlib.loads(plist.encode())['LSMinimumSystemVersion']=='10.15'
        for name in ('GeneradorPDFMacIntel',):
            assert has_x86_64(member(z,OLD_APP+'Contents/Resources/'+name)),f'{name} is not x86_64 Mach-O'
        for name in ('ffmpeg','ffprobe'):
            data=member(z,OLD_APP+'Contents/Resources/'+name)
            assert has_x86_64(data[:128]),f'{name} is not x86_64 Mach-O'
    print('PASS: base archive and component hashes match')
    print('PASS: classification, depth, analysis and conversion code is unchanged outside report/PDF scope')
    print('PASS: duplicate analysis remains disabled; user reports omit duplicate claims; technical diagnostics remain')
    print('PASS: app labels are V2.12.19 and existing x86_64 dependencies remain byte-identical')

def verify_pdfs():
    paths=[ROOT/'docs'/'01 Cómo abrir.pdf',ROOT/'docs'/'02 Qué hace y cómo trabaja.pdf']
    for path,expected_pages in zip(paths,(1,2)):
        with pdfplumber.open(path) as pdf:
            assert len(pdf.pages)==expected_pages,(path,len(pdf.pages))
            for page in pdf.pages:
                assert abs(page.width-595.276)<1 and abs(page.height-841.89)<1,(path,page.width,page.height)
            text='\n'.join(page.extract_text() or '' for page in pdf.pages)
            assert 'V2.12.19' in text
            assert 'FFmpeg' in text or 'PDF' in text
            assert '\ufffd' not in text,'replacement character in generated PDF'
            assert not any(c in text for c in ('\u2011','\u2013','\u2014')),'unsupported non-ASCII dash in PDF text'
    print('PASS: guide PDFs are readable, A4, and have the expected page counts')

def verify_package(package,base):
    with zipfile.ZipFile(package) as z, zipfile.ZipFile(base) as original:
        bad=z.testzip(); assert bad is None,bad
        for name in (NEW_APP+'Contents/MacOS/AnalizadorMultitracks',NEW_APP+'Contents/Resources/AnalizadorMultitracksV2.command',NEW_APP+'Contents/Resources/PublishPDFReports.sh',NEW_APP+'Contents/Resources/GeneradorPDFMacIntel',NEW_APP+'Contents/Resources/ffmpeg',NEW_APP+'Contents/Resources/ffprobe',NEW_ROOT+'01 Cómo abrir.pdf',NEW_ROOT+'02 Qué hace y cómo trabaja.pdf',NEW_ROOT+'MANIFEST.json'):
            info=next((i for i in z.infolist() if canonical(i)==name),None)
            assert info is not None,f'missing package file: {name}'
        for name in (NEW_APP+'Contents/MacOS/AnalizadorMultitracks',NEW_APP+'Contents/Resources/AnalizadorMultitracksV2.command',NEW_APP+'Contents/Resources/PublishPDFReports.sh',NEW_APP+'Contents/Resources/ffmpeg',NEW_APP+'Contents/Resources/ffprobe'):
            info=next(i for i in z.infolist() if canonical(i)==name)
            assert ((info.external_attr>>16)&0o111)!=0,f'executable permission missing: {name}'
        for name in ('GeneradorPDFMacIntel','ffmpeg','ffprobe'):
            data=member(z,NEW_APP+'Contents/Resources/'+name)
            assert has_x86_64(data[:128]),f'{name} is not x86_64'
            assert sha(data)==EXPECTED[name],f'{name} changed in final package'
        for name in ('EffectiveDepth.pl','DejaVuSans.ttf','DejaVuSans-Bold.ttf','AppIcon.icns','LICENCIA_FUENTE_DEJAVU.txt'):
            assert sha(member(z,NEW_APP+'Contents/Resources/'+name))==EXPECTED[name],f'{name} changed in final package'
        plist=plistlib.loads(member(z,NEW_APP+'Contents/Info.plist'))
        assert plist['CFBundleShortVersionString']=='2.12.19' and plist['CFBundleVersion']=='2.12.19'
        assert plist['LSMinimumSystemVersion']=='10.15'
        assert member(z,NEW_APP+'Contents/Resources/GeneradorPDFMacIntel')==member(original,OLD_APP+'Contents/Resources/GeneradorPDFMacIntel')
        manifest=json.loads(member(z,NEW_ROOT+'MANIFEST.json'))
        assert manifest['version']=='2.12.19' and manifest['platform']=='macOS Intel x86_64'
        for rel,digest in manifest['components'].items():
            assert sha(member(z,NEW_ROOT+rel))==digest,f'manifest hash mismatch: {rel}'
        names=[canonical(i) for i in z.infolist()]
        assert not any(name.startswith(OLD_ROOT) for name in names),'V2.12.18 paths leaked into the V2.12.19 package'
    print('PASS: final ZIP integrity, paths, executable modes, version, dependency hashes, and Intel architecture')

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--base-package',required=True,type=Path)
    parser.add_argument('--package',type=Path)
    args=parser.parse_args()
    verify_source(args.base_package.resolve())
    verify_pdfs()
    if args.package: verify_package(args.package.resolve(),args.base_package.resolve())

if __name__=='__main__': main()
