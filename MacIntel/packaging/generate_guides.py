from pathlib import Path
import re
from xml.sax.saxutils import escape
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import Flowable, PageBreak, Paragraph, SimpleDocTemplate, Spacer

ROOT=Path(__file__).resolve().parents[1]
DOCS=ROOT/'docs'
FONTS=ROOT/'app'/'Contents'/'Resources'
VERSION='V2.12.19'
NAVY=colors.HexColor('#19334B')
BLUE=colors.HexColor('#218ACB')
PALE=colors.HexColor('#E6F0F4')
TEXT=colors.HexColor('#263D53')
RULE=colors.HexColor('#B7D0DE')

pdfmetrics.registerFont(TTFont('DejaVu',str(FONTS/'DejaVuSans.ttf')))
pdfmetrics.registerFont(TTFont('DejaVu-Bold',str(FONTS/'DejaVuSans-Bold.ttf')))

class SectionHeader(Flowable):
    def __init__(self,text):
        super().__init__(); self.text=text; self.height=22
    def wrap(self,availWidth,availHeight):
        self.width=availWidth; return availWidth,self.height
    def draw(self):
        c=self.canv
        c.setFillColor(PALE); c.rect(0,0,self.width,self.height,fill=1,stroke=0)
        c.setFillColor(BLUE); c.rect(0,0,3.5,self.height,fill=1,stroke=0)
        style=ParagraphStyle('section',fontName='DejaVu-Bold',fontSize=10.4,leading=12.4,textColor=NAVY)
        para=Paragraph(escape(self.text),style)
        w,h=para.wrap(self.width-19,self.height-4)
        para.drawOn(c,10,(self.height-h)/2)

def decorate(canvas,doc):
    width,height=A4
    canvas.saveState()
    canvas.setFillColor(NAVY); canvas.rect(0,height-18,width,18,fill=1,stroke=0)
    canvas.setFillColor(colors.HexColor('#66839D'))
    canvas.setFont('DejaVu-Bold',7.35)
    canvas.drawString(60,height-61,f'ANALIZADOR DE MULTITRACKS ESTUDIO PG {VERSION} - MAC INTEL')
    canvas.setStrokeColor(RULE); canvas.setLineWidth(.55)
    canvas.line(50,35,width-50,35)
    canvas.restoreState()

TITLE=ParagraphStyle('title',fontName='DejaVu-Bold',fontSize=23,leading=27,textColor=NAVY,spaceBefore=1,spaceAfter=9)
BODY=ParagraphStyle('body',fontName='DejaVu',fontSize=10.2,leading=14.2,textColor=TEXT,spaceAfter=3.3)
TIGHT=ParagraphStyle('tight',parent=BODY,spaceAfter=1.2)
NUMBER=ParagraphStyle('number',parent=BODY,leftIndent=18,firstLineIndent=-18)
BULLET=ParagraphStyle('bullet',parent=TIGHT,leftIndent=13,firstLineIndent=-9)

def rich(text):
    safe=escape(text)
    return re.sub(r'\*\*(.+?)\*\*',r'<b>\1</b>',safe)

def parse_source(path,page_break_before=None):
    lines=path.read_text(encoding='utf-8').splitlines()
    story=[]; first_heading=True; in_list=False
    def flush_list():
        nonlocal in_list
        in_list=False
    for line in lines:
        if not line.strip():
            flush_list(); continue
        if line.startswith('# '):
            continue
        if line.startswith('## '):
            flush_list(); heading=line[3:].strip()
            if first_heading:
                story.append(Paragraph(escape(heading),TITLE)); first_heading=False
            else:
                if heading==page_break_before: story.append(PageBreak())
                story.extend([Spacer(1,3),SectionHeader(heading),Spacer(1,4)])
            continue
        if line.startswith('- '):
            in_list=True; story.append(Paragraph('•&nbsp;'+rich(line[2:].strip()),BULLET)); continue
        match=re.match(r'^(\d+)\.\s+(.*)$',line)
        if match:
            in_list=True
            para=Paragraph(match.group(1)+'.&nbsp;'+rich(match.group(2)),NUMBER)
            story.append(para); continue
        flush_list(); story.append(Paragraph(rich(line.strip()),BODY))
    return story

def build(source_name,output_name,page_break_before=None):
    source=DOCS/'source'/source_name
    output=DOCS/output_name
    doc=SimpleDocTemplate(str(output),pagesize=A4,leftMargin=60,rightMargin=60,topMargin=88,bottomMargin=45,title=source_name.removesuffix('.md'),author='Estudio PG',subject='Documentación Mac Intel V2.12.19')
    doc.build(parse_source(source,page_break_before),onFirstPage=decorate,onLaterPages=decorate)
    print(f'Created {output}')

build('01 Cómo abrir.md','01 Cómo abrir.pdf')
build('02 Qué hace y cómo trabaja.md','02 Qué hace y cómo trabaja.pdf',page_break_before='INFORMES')
