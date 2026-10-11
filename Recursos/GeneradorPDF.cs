// Generador autocontenido de informes PDF para Windows PowerShell 5.1.
// Incorpora fuentes TrueType en el PDF; no usa impresoras ni navegadores.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace EstudioPG {
  public sealed class FontData {
    public readonly byte[] Bytes;
    readonly Dictionary<string,int> tables = new Dictionary<string,int>();
    readonly int upem, hmtx, metrics, cmap, groups, groupCount, format;
    readonly int[] adv;
    public readonly string Name;
    public readonly int Ascender, Descender, XMin, YMin, XMax, YMax;
    public readonly SortedDictionary<int,int> Used = new SortedDictionary<int,int>();
    int U16(int p) { return (Bytes[p] << 8) | Bytes[p+1]; }
    int S16(int p) { return (short)U16(p); }
    long U32(int p) {
      return ((long)Bytes[p] * 16777216L) + ((long)Bytes[p+1] * 65536L)
           + ((long)Bytes[p+2] * 256L) + Bytes[p+3];
    }
    public FontData(string path, string name) {
      Bytes = File.ReadAllBytes(path); Name = name;
      int n = U16(4);
      for (int i=0;i<n;i++) { int at=12+i*16; tables[Encoding.ASCII.GetString(Bytes,at,4)] = (int)U32(at+8); }
      int head=tables["head"], hh=tables["hhea"], max=tables["maxp"];
      upem=U16(head+18); XMin=S16(head+36); YMin=S16(head+38);
      XMax=S16(head+40); YMax=S16(head+42);
      Ascender=S16(hh+4); Descender=S16(hh+6);
      metrics=U16(hh+34); hmtx=tables["hmtx"];
      int glyphs=U16(max+4); adv=new int[glyphs];
      for(int i=0;i<glyphs;i++) adv[i]=U16(hmtx+4*Math.Min(i,metrics-1));
      int ct=tables["cmap"], sub=U16(ct+2), chosen=0;
      for(int i=0;i<sub;i++) {
        int at=ct+4+i*8, platform=U16(at), enc=U16(at+2), off=ct+(int)U32(at+4);
        int f=U16(off);
        if (f==12 && (platform==3 && enc==10 || platform==0)) { chosen=off; break; }
        if (chosen==0 && f==4 && (platform==3 || platform==0)) chosen=off;
      }
      if(chosen==0) throw new InvalidDataException("La fuente no contiene cmap Unicode.");
      cmap=chosen; format=U16(cmap);
      if(format==12) { groups=cmap+16; groupCount=(int)U32(cmap+12); }
    }
    public int Glyph(int code) {
      if(format==12) {
        int lo=0, hi=groupCount-1;
        while(lo<=hi) { int mid=(lo+hi)/2, at=groups+mid*12;
          long start=U32(at), end=U32(at+4);
          if(code<start) hi=mid-1; else if(code>end) lo=mid+1;
          else return (int)(U32(at+8)+code-start);
        }
        return 0;
      }
      int seg=U16(cmap+6)/2, ends=cmap+14, starts=ends+2*seg+2;
      int deltas=starts+2*seg, ranges=deltas+2*seg;
      for(int i=0;i<seg;i++) {
        if(code>U16(ends+2*i)) continue;
        if(code<U16(starts+2*i)) return 0;
        int range=U16(ranges+2*i);
        if(range==0) return (code+S16(deltas+2*i)) & 65535;
        int p=ranges+2*i+range+2*(code-U16(starts+2*i));
        int glyph=U16(p);
        return glyph==0?0:(glyph+S16(deltas+2*i)) & 65535;
      }
      return 0;
    }
    public int Width(int glyph) { return (int)Math.Round(1000.0*adv[Math.Max(0,Math.Min(glyph,adv.Length-1))]/upem); }
    public int Scale(int value) { return (int)Math.Round(1000.0*value/upem); }
    public double Measure(string s, double size) {
      double w=0;
      foreach(char c in s) w += Width(Glyph(c))/1000.0*size;
      return w;
    }
    public string Hex(string s) {
      StringBuilder b=new StringBuilder(s.Length*4);
      foreach(char c in s) {
        int glyph=Glyph(c);
        if(glyph==0 && c!='\0') glyph=Glyph('?');
        if(!Used.ContainsKey(glyph)) Used[glyph]=(int)c;
        b.Append(glyph.ToString("X4",CultureInfo.InvariantCulture));
      }
      return b.ToString();
    }
    public string Widths() {
      StringBuilder b=new StringBuilder();
      foreach(int g in Used.Keys) b.Append(g.ToString(CultureInfo.InvariantCulture)).Append(" [").Append(Width(g)).Append("] ");
      return b.ToString();
    }
    public byte[] CMap() {
      StringBuilder b=new StringBuilder("/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /PGUnicode def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n");
      var pairs=Used.ToArray();
      for(int start=0;start<pairs.Length;start+=100) {
        int count=Math.Min(100,pairs.Length-start);
        b.Append(count).Append(" beginbfchar\n");
        for(int i=start;i<start+count;i++) b.Append('<').Append(pairs[i].Key.ToString("X4")).Append("> <").Append(pairs[i].Value.ToString("X4")).Append(">\n");
        b.Append("endbfchar\n");
      }
      b.Append("endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
      return Encoding.ASCII.GetBytes(b.ToString());
    }
  }

  public sealed class PdfFile {
    readonly List<byte[]> objects=new List<byte[]>();
    static readonly Encoding A=Encoding.ASCII;
    public int Reserve() { objects.Add(null); return objects.Count; }
    public int Add(string body) { int id=Reserve(); Set(id,A.GetBytes(body)); return id; }
    public void Set(int id, byte[] body) { objects[id-1]=body; }
    public void Set(int id,string body) { Set(id,A.GetBytes(body)); }
    static byte[] Stream(string header,byte[] data) {
      byte[] h=A.GetBytes(header+"\nstream\n"), t=A.GetBytes("\nendstream");
      byte[] b=new byte[h.Length+data.Length+t.Length];
      Buffer.BlockCopy(h,0,b,0,h.Length); Buffer.BlockCopy(data,0,b,h.Length,data.Length);
      Buffer.BlockCopy(t,0,b,h.Length+data.Length,t.Length); return b;
    }
    public int AddStream(byte[] data) {
      int id=Reserve(); Set(id,Stream("<< /Length "+data.Length+" >>",data)); return id;
    }
    public int AddFont(FontData f) {
      int file=Reserve(), descriptor=Reserve(), descendant=Reserve(), cmap=Reserve(), root=Reserve();
      Set(file,Stream("<< /Length "+f.Bytes.Length+" /Length1 "+f.Bytes.Length+" >>",f.Bytes));
      byte[] map=f.CMap(); Set(cmap,Stream("<< /Length "+map.Length+" >>",map));
      string box=string.Format(CultureInfo.InvariantCulture,"[{0} {1} {2} {3}]",f.Scale(f.XMin),f.Scale(f.YMin),f.Scale(f.XMax),f.Scale(f.YMax));
      Set(descriptor,"<< /Type /FontDescriptor /FontName /"+f.Name+" /Flags 32 /FontBBox "+box+
        " /ItalicAngle 0 /Ascent "+f.Scale(f.Ascender)+" /Descent "+f.Scale(f.Descender)+
        " /CapHeight "+f.Scale(f.Ascender)+" /StemV 90 /FontFile2 "+file+" 0 R >>");
      Set(descendant,"<< /Type /Font /Subtype /CIDFontType2 /BaseFont /"+f.Name+
        " /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>"+
        " /FontDescriptor "+descriptor+" 0 R /DW 1000 /W ["+f.Widths()+"] /CIDToGIDMap /Identity >>");
      Set(root,"<< /Type /Font /Subtype /Type0 /BaseFont /"+f.Name+
        " /Encoding /Identity-H /DescendantFonts ["+descendant+" 0 R] /ToUnicode "+cmap+" 0 R >>");
      return root;
    }
    public void Save(string path,int catalog) {
      using(FileStream f=new FileStream(path,FileMode.Create,FileAccess.Write)) {
        byte[] start=A.GetBytes("%PDF-1.4\n%\xD0\xD0\xD0\xD0\n"); f.Write(start,0,start.Length);
        List<long> offsets=new List<long>(); offsets.Add(0);
        for(int i=0;i<objects.Count;i++) {
          if(objects[i]==null) throw new InvalidDataException("Objeto PDF sin definir: "+(i+1));
          offsets.Add(f.Position);
          byte[] h=A.GetBytes((i+1)+" 0 obj\n"), t=A.GetBytes("\nendobj\n");
          f.Write(h,0,h.Length); f.Write(objects[i],0,objects[i].Length); f.Write(t,0,t.Length);
        }
        long xref=f.Position;
        byte[] pre=A.GetBytes("xref\n0 "+(objects.Count+1)+"\n0000000000 65535 f \n"); f.Write(pre,0,pre.Length);
        for(int i=1;i<offsets.Count;i++) { byte[] row=A.GetBytes(offsets[i].ToString("D10")+" 00000 n \n"); f.Write(row,0,row.Length); }
        byte[] end=A.GetBytes("trailer\n<< /Size "+(objects.Count+1)+" /Root "+catalog+" 0 R >>\nstartxref\n"+xref+"\n%%EOF\n");
        f.Write(end,0,end.Length);
      }
    }
  }

  public sealed class PdfReport {
    const double H=841.89, W=595.28, L=48, R=48, Bottom=60;
    const string Ink="0.10 0.16 0.23", Muted="0.39 0.46 0.54", Blue="0.14 0.46 0.66";
    const string Amber="0.65 0.40 0.08";
    readonly FontData normal,bold;
    readonly List<string> pages=new List<string>();
    StringBuilder draw;
    double y;
    int number;
    PdfReport(string regular,string heavy) {
      normal=new FontData(regular,"DejaVuSans"); bold=new FontData(heavy,"DejaVuSans-Bold");
    }
    static string F(double n) { return n.ToString("0.###",CultureInfo.InvariantCulture); }
    void Rect(double x,double bottom,double w,double h,string color) {
      draw.Append(color).Append(" rg ").Append(F(x)).Append(' ').Append(F(bottom)).Append(' ').Append(F(w)).Append(' ').Append(F(h)).Append(" re f\n");
    }
    void Rule(double yy) { Rect(L,yy,W-L-R,0.75,"0.85 0.89 0.92"); }
    void Text(string s,double x,double baseline,double size,bool heavy,string color) {
      FontData font=heavy?bold:normal;
      draw.Append(color).Append(" rg BT /").Append(heavy?"F2":"F1").Append(' ').Append(F(size))
        .Append(" Tf 1 0 0 1 ").Append(F(x)).Append(' ').Append(F(baseline)).Append(" Tm <")
        .Append(font.Hex(s)).Append("> Tj ET\n");
    }
    void NewPage() {
      if(draw!=null) pages.Add(draw.ToString());
      number++; draw=new StringBuilder(); y=H-55;
      Rect(0,H-8,W,8,Ink);
      Rule(44);
      Text("ESTUDIO PG  /  ANALIZADOR DE MULTITRACKS",L,31,7,true,Muted);
      Text("INFORME PDF  ·  "+number.ToString("D2"),W-R-97,31,7,false,Muted);
    }
    void Need(double required) { if(y-required<Bottom) NewPage(); }
    List<string> Wrap(string s,FontData font,double size,double maxWidth) {
      List<string> result=new List<string>(); StringBuilder row=new StringBuilder();
      foreach(string word in s.Split(new char[]{' '},StringSplitOptions.None)) {
        string trial=row.Length==0?word:row.ToString()+" "+word;
        if(font.Measure(trial,size)<=maxWidth) { row.Clear(); row.Append(trial); continue; }
        if(row.Length>0) { result.Add(row.ToString()); row.Clear(); }
        foreach(char c in word) {
          if(row.Length>0 && font.Measure(row.ToString()+c,size)>maxWidth) { result.Add(row.ToString()); row.Clear(); }
          row.Append(c);
        }
      }
      result.Add(row.ToString()); return result;
    }
    void Line(string s,double size,bool heavy,string color,double indent,double leading,double gap) {
      FontData font=heavy?bold:normal;
      List<string> rows=Wrap(s,font,size,W-L-R-indent);
      Need(rows.Count*leading+gap);
      foreach(string row in rows) { Text(row,L+indent,y,size,heavy,color); y-=leading; }
      y-=gap;
    }
    void Heading(string s,bool major) {
      Need(major?52:35);
      if(major) {
        y-=9;
        Rect(L,y-10,W-L-R,27,"0.91 0.945 0.96");
        Rect(L,y-10,4,27,Blue);
        Text(ToTitle(s),L+12,y,11.2,true,Ink);
        y-=28;
      } else {
        y-=8;
        Text(s,L+3,y,9.1,true,Ink);
        y-=15;
      }
    }
    static string ToTitle(string s) {
      if(s=="CONTROL DE FORMATO Y DURACIÓN") return "Control de formato y duración";
      if(s=="PROFUNDIDAD EFECTIVA / ALMACENAMIENTO") return "Profundidad efectiva / almacenamiento";
      if(s=="CONTROL FLOAT SOBRE 0 dBFS") return "Control FLOAT sobre 0 dBFS";
      if(s=="RESUMEN OPERATIVO") return "Resumen operativo";
      string a=s.ToLowerInvariant(); return a.Length==0?a:char.ToUpperInvariant(a[0])+a.Substring(1);
    }
    void Accent(string s,bool warning) {
      List<string> rows=Wrap(s,normal,8,W-L-R-28);
      double height=rows.Count*12+12;
      Need(height+7);
      Rect(L,y-height+8,W-L-R,height,warning?"1 0.96 0.88":"0.94 0.965 0.976");
      Rect(L,y-height+8,3,height,warning?Amber:Blue);
      double yy=y-9;
      foreach(string row in rows) { Text(row,L+13,yy,8,false,Ink); yy-=12; }
      y-=height+7;
    }
    void Cards(int total,int converted,int review,int duplicates) {
      Need(65); Rect(L,y-48,W-L-R,55,"0.94 0.965 0.976");
      int[] nums={total,converted,review,duplicates};
      string[] labels={"WAV analizados","Convertidos a mono","Para revisar","Grupos duplicados"};
      for(int i=0;i<4;i++) { double x=L+12+i*(W-L-R)/4;
        Text(nums[i].ToString(),x,y-23,19,true,Ink); Text(labels[i],x,y-39,7,false,Muted);
      }
      y-=70;
    }
    static int Value(string data,string prefix) {
      foreach(string line in data.Split('\n')) if(line.TrimStart().StartsWith(prefix,StringComparison.OrdinalIgnoreCase)) {
        string tail=line.Substring(line.IndexOf(':')+1).Trim(); int n;
        if(int.TryParse(tail,out n)) return n;
      }
      return 0;
    }
    static int GroupCount(string data) {
      string key="Duplicados: ";
      foreach(string line in data.Split('\n')) if(line.StartsWith(key)) {
        string first=line.Substring(key.Length).Split(' ')[0]; int n;
        if(int.TryParse(first,out n)) return n;
      }
      return 0;
    }
    void Render(string text,bool isBasic) {
      NewPage();
      string[] lines=text.Replace("\r\n","\n").Replace('\r','\n').Split('\n');
      string title=isBasic?"Informe básico":"Informe detallado";
      Text("ESTUDIO PG   /   ANALIZADOR DE MULTITRACKS",L,y,7.2,true,Muted); y-=26;
      Line(title,21,true,Ink,0,26,4);
      Line("Resultado de la sesión  ·  "+(isBasic?"Resumen operativo":"Evidencia por archivo"),9,false,Muted,0,13,13);
      if(isBasic) Cards(Value(text,"Total WAV:"),Value(text,"Convertidos a mono:"),Value(text,"Archivos para revisar:"),GroupCount(text));
      bool first=true; bool inDuplicates=false; bool inDetail=false;
      for(int i=0;i<lines.Length;i++) {
        string line=lines[i].Trim();
        if(line.Length==0 || line.All(c=>c=='=') || line.All(c=>c=='-')) continue;
        if(first) { first=false; continue; } // Encabezado TXT; el PDF tiene su título propio.
        if(line=="Carpeta analizada:" || line=="Carpeta original:" || line=="Carpeta procesada:") {
          if(i+1<lines.Length && lines[i+1].Trim().Length>0 && !lines[i+1].Trim().StartsWith("=")) {
            Heading(line.ToUpperInvariant(),false);
            Line(lines[++i].Trim(),7.3,false,Ink,0,10,7);
          } else Line(line,8.2,false,Ink,0,12,5);
          continue;
        }
        if(line=="ARCHIVOS DUPLICADOS" || line=="PISTAS DUPLICADAS") inDuplicates=true;
        bool major=IsMajor(line);
        if(major) {
          inDetail=(!isBasic && line=="DETALLE");
          Heading(line,true); continue;
        }
        if(inDetail) {
          int separator=line.IndexOf(" -> ",StringComparison.Ordinal);
          if(separator>0) {
            string file=line.Substring(0,separator);
            string result=line.Substring(separator+4);
            int fileRows=Wrap(file,bold,7.8,W-L-R-11).Count;
            int resultRows=Wrap(result,normal,7.7,W-L-R-25).Count;
            Need(fileRows*11.3+resultRows*10.9+8);
            Line(file,7.8,true,Ink,11,11.3,1);
            Line(result,7.7,false,Muted,25,10.9,6);
            continue;
          }
        }
        if(IsMinor(line)) { Heading(line,false); continue; }
        if(line.StartsWith("ATENCIÓN") || line.StartsWith("ESTADO:")) { Accent(line,true); continue; }
        if(line.StartsWith("- ") && !inDuplicates) {
          Line("• "+line.Substring(2),8.1,false,Ink,11,11,3); continue;
        }
        if(line.StartsWith("Grupo ") || line.StartsWith("GRUPO ")) { Heading(line.ToUpperInvariant(),false); continue; }
        if(isBasic && (line.StartsWith("1. ") || line.StartsWith("2. ")) && line.Contains(" -> Posible mono")) {
          Accent(line,true); continue;
        }
        bool emphasize=line.StartsWith("Referencia:") || line.StartsWith("Resultado:") || line.StartsWith("TOTAL ");
        double indent=lines[i].StartsWith("   ") || lines[i].StartsWith("  ")?11:0;
        double size=isBasic?8.0:7.7;
        Line(line,size,emphasize,Ink,indent,isBasic?11.2:10.8,
          line.StartsWith("Referencia:") || line.StartsWith("Ninguno.")?5:2.8);
      }
      pages.Add(draw.ToString()); draw=null;
    }
    static bool IsMajor(string s) {
      string[] major={"FORMATO PARA CREAR LA SESIÓN","ACCIONES REALIZADAS","CLASIFICACIÓN","PROFUNDIDAD EFECTIVA","OTRAS ADVERTENCIAS","ARCHIVOS PARA REVISAR","RESUMEN OPERATIVO","DETALLE","CONTROL DE FORMATO Y DURACIÓN","CONTROL DE DUPLICADOS","CONTROL FLOAT SOBRE 0 dBFS","CONTROL DE NIVEL","RESUMEN"};
      return major.Contains(s);
    }
    static bool IsMinor(string s) {
      if(s.Length<4 || s.Length>85 || s!=s.ToUpperInvariant()) return false;
      if(s.IndexOf(':')>=0 || s.IndexOf('\\')>=0 || s.IndexOf('.')>=0) return false;
      return s.Any(char.IsLetter);
    }
    void Write(string path) {
      PdfFile pdf=new PdfFile();
      int catalog=pdf.Reserve(), rootPages=pdf.Reserve();
      int[] pageIds=new int[pages.Count];
      for(int i=0;i<pages.Count;i++) pageIds[i]=pdf.Reserve();
      int reg=pdf.AddFont(normal), heavy=pdf.AddFont(bold);
      for(int i=0;i<pages.Count;i++) {
        int content=pdf.AddStream(Encoding.ASCII.GetBytes(pages[i]));
        pdf.Set(pageIds[i],"<< /Type /Page /Parent "+rootPages+" 0 R /MediaBox [0 0 595.28 841.89] "+
          "/Resources << /Font << /F1 "+reg+" 0 R /F2 "+heavy+" 0 R >> >> /Contents "+content+" 0 R >>");
      }
      StringBuilder kids=new StringBuilder(); foreach(int id in pageIds) kids.Append(id).Append(" 0 R ");
      pdf.Set(rootPages,"<< /Type /Pages /Count "+pageIds.Length+" /Kids ["+kids+"] >>");
      pdf.Set(catalog,"<< /Type /Catalog /Pages "+rootPages+" 0 R >>");
      pdf.Save(path,catalog);
    }
    public static void Generate(string input,string output,string regular,string bold,bool isBasic) {
      PdfReport r=new PdfReport(regular,bold);
      r.Render(File.ReadAllText(input,Encoding.UTF8).TrimStart('\uFEFF'),isBasic);
      string temp=output+".tmp";
      try { r.Write(temp); if(File.Exists(output)) File.Delete(output); File.Move(temp,output); }
      finally { if(File.Exists(temp)) File.Delete(temp); }
    }
  }
}
