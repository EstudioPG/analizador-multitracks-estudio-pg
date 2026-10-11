#!/usr/bin/perl
use strict;
use warnings;
use Time::HiRes qw(time);
my $PROFILE_START = time();
use bytes;

# Analizador de profundidad efectiva para WAV PCM entero/FLOAT.
# V2.12.9: mantiene la optimización conservadora PCM24/PCM32; los archivos silenciosos se filtran previamente en el script principal.
# Mantiene los mismos criterios de decisión. Para PCM24 normal, abandona
# el recorrido cuando ya es matemáticamente imposible alcanzar los umbrales
# FUERTE o PARCIAL aun suponiendo que todas las muestras restantes fueran favorables.
# Para PCM32, abandona en cuanto ya no puede existir patrón exacto 24/16.
# Residual inferior PCM24: -128..+127 (256 estados).

sub read_exact {
    my ($fh, $n) = @_;
    my $buf = '';
    my $got = read($fh, $buf, $n);
    die "Lectura incompleta" if !defined($got) || $got != $n;
    return $buf;
}
sub u16le { return unpack('v', $_[0]); }
sub u32le { return unpack('V', $_[0]); }

sub entropy_counts {
    my ($counts, $total) = @_;
    return 0.0 if !$total;
    my $h = 0.0;
    for my $c (@$counts) {
        next unless $c;
        my $p = $c / $total;
        $h -= $p * (log($p)/log(2));
    }
    return $h;
}

sub print_result {
    my (%r) = @_;
    my @f = map { defined($_) ? $_ : '' } (
        $r{valid}, $r{encoding}, $r{container_bits}, $r{valid_bits},
        $r{strict}, $r{pattern}, $r{nonzero}, $r{common_zero_lsb},
        $r{grid_exact_pct}, $r{grid_within2_pct}, $r{grid_rms},
        $r{grid_residual_entropy}, $r{grid_distinct_residuals}, $r{error}
    );
    for (@f) { s/[\t\r\n]+/ /g if defined; }
    my $elapsed_ms = (time() - $PROFILE_START) * 1000.0;
    push @f, sprintf('%.3f', $elapsed_ms);
    print join("\t", @f), "\n";
}

my $path = shift @ARGV;
if (!defined $path || $path eq '') {
    print_result(valid=>0,error=>'Ruta no especificada');
    exit 1;
}
open(my $fh, '<:raw', $path) or do {
    print_result(valid=>0,error=>"No se pudo abrir: $!");
    exit 1;
};

my ($format_tag,$channels,$block_align,$bits,$valid_bits,$subformat_tag);
my ($data_start,$data_size);
my $riff = read_exact($fh,4);
if ($riff ne 'RIFF' && $riff ne 'RF64') {
    print_result(valid=>0,error=>'No es WAV RIFF/RF64'); exit 0;
}
read_exact($fh,4);
my $wave = read_exact($fh,4);
if ($wave ne 'WAVE') { print_result(valid=>0,error=>'WAVE inválido'); exit 0; }

while (1) {
    my $hdr;
    my $n = read($fh,$hdr,8);
    last if !defined($n) || $n < 8;
    my $id = substr($hdr,0,4);
    my $size = u32le(substr($hdr,4,4));
    my $chunk_start = tell($fh);

    if ($id eq 'fmt ') {
        my $need = $size < 40 ? $size : 40;
        my $fmt = read_exact($fh,$need);
        if (length($fmt) >= 16) {
            $format_tag  = u16le(substr($fmt,0,2));
            $channels    = u16le(substr($fmt,2,2));
            $block_align = u16le(substr($fmt,12,2));
            $bits        = u16le(substr($fmt,14,2));
            $valid_bits  = $bits;
            if ($format_tag == 0xFFFE && length($fmt) >= 40) {
                my $cb = u16le(substr($fmt,16,2));
                if ($cb >= 22) {
                    $valid_bits = u16le(substr($fmt,18,2));
                    $subformat_tag = u32le(substr($fmt,24,4));
                }
            }
        }
    }
    elsif ($id eq 'data') {
        $data_start = tell($fh);
        if ($size == 0xFFFFFFFF) {
            seek($fh,0,2);
            $data_size = tell($fh) - $data_start;
        } else {
            $data_size = $size;
        }
        last;
    }
    my $next = $chunk_start + $size + ($size % 2);
    seek($fh,$next,0) or last;
}

if (!defined($data_start) || !$channels || !$bits) {
    print_result(valid=>0,error=>'No se pudo leer fmt/data'); exit 0;
}

my $is_pcm   = ($format_tag == 1) ? 1 : 0;
my $is_float = ($format_tag == 3) ? 1 : 0;
if ($format_tag == 0xFFFE && defined $subformat_tag) {
    $is_pcm   = 1 if $subformat_tag == 1;
    $is_float = 1 if $subformat_tag == 3;
}
$valid_bits = $bits if !$valid_bits;

if ($is_float) {
    print_result(valid=>1,encoding=>'PCM FLOAT',container_bits=>$bits,valid_bits=>$valid_bits,
        strict=>'FLOAT 32 - PROFUNDIDAD EFECTIVA NO DETERMINADA',pattern=>'NO APLICA',
        nonzero=>'',common_zero_lsb=>-1,grid_exact_pct=>'',grid_within2_pct=>'',grid_rms=>'',
        grid_residual_entropy=>'',grid_distinct_residuals=>'',error=>'');
    exit 0;
}
if (!$is_pcm) {
    print_result(valid=>1,encoding=>'OTRO / NO PCM',container_bits=>$bits,valid_bits=>$valid_bits,
        strict=>'PROFUNDIDAD EFECTIVA NO DETERMINADA',pattern=>'NO APLICA',error=>'');
    exit 0;
}
if ($bits != 16 && $bits != 24 && $bits != 32) {
    print_result(valid=>1,encoding=>'PCM ENTERO',container_bits=>$bits,valid_bits=>$valid_bits,
        strict=>'PCM ENTERO - PROFUNDIDAD NO SOPORTADA',pattern=>'NO APLICA',error=>'');
    exit 0;
}
if ($bits == 16) {
    print_result(valid=>1,encoding=>'PCM ENTERO',container_bits=>16,valid_bits=>$valid_bits,
        strict=>'PCM ENTERO 16',pattern=>'NO APLICA',common_zero_lsb=>0,error=>'');
    exit 0;
}

seek($fh,$data_start,0) or die "No se pudo posicionar en data";
my $bytes_per_sample = int($bits/8);
my $total_samples = int($data_size / $bytes_per_sample);
my $remaining = $data_size;
my $carry = '';
my $nonzero = 0;
my $samples_seen = 0;
my $exact16_possible = 1;
my $exact24_possible = 1; # solo PCM32
my @res_counts = $bits == 24 ? ((0) x 256) : ();
my ($grid_exact,$grid2,$grid_sq) = (0,0,0.0);
my $early_no_pattern = 0;

# 4 MiB reduce overhead de read/unpack sin disparar demasiado la memoria.
my $chunk_size = 4*1024*1024;
while ($remaining > 0) {
    my $want = $remaining < $chunk_size ? $remaining : $chunk_size;
    my $buf = '';
    my $got = read($fh,$buf,$want);
    last if !defined($got) || $got <= 0;
    $remaining -= $got;
    $buf = $carry . $buf;
    my $usable = length($buf) - (length($buf) % $bytes_per_sample);
    $carry = substr($buf,$usable);

    if ($bits == 24) {
        my @b = unpack('C*', substr($buf,0,$usable));
        my $count = scalar(@b);
        for (my $i=0; $i<$count; $i+=3) {
            $samples_seen++;
            my $b0 = $b[$i];
            my $b1 = $b[$i+1];
            my $b2 = $b[$i+2];
            next if (($b0 | $b1 | $b2) == 0);

            $nonzero++;
            if ($b0 != 0) { $exact16_possible = 0; }

            my $res = ($b0 >= 128) ? ($b0 - 256) : $b0;
            my $abs = $res < 0 ? -$res : $res;
            $res_counts[$res+128]++;
            $grid_exact++ if $abs == 0;
            $grid2++ if $abs <= 2;
            $grid_sq += $res*$res;
        }

        # Salida temprana SEGURA para PCM24 normal:
        # si ya apareció un LSB no cero, el patrón exacto 16-bit es imposible.
        # Para FUERTE/PARCIAL calculamos el mejor escenario posible: TODAS las
        # muestras aún no vistas serían no-cero y favorables. Si ni así alcanza
        # 95% (±2) o 90% (exactas), no existe forma de que el resultado final
        # cambie y podemos omitir el resto del archivo.
        if (!$exact16_possible && $nonzero > 0) {
            my $remaining_samples = $total_samples - $samples_seen;
            $remaining_samples = 0 if $remaining_samples < 0;
            my $best_den = $nonzero + $remaining_samples;
            if ($best_den > 0) {
                my $best_grid2 = 100.0 * ($grid2 + $remaining_samples) / $best_den;
                my $best_exact = 100.0 * ($grid_exact + $remaining_samples) / $best_den;
                if ($best_grid2 < 95.0 && $best_exact < 90.0) {
                    $early_no_pattern = 1;
                    last;
                }
            }
        }
    }
    else { # PCM32 entero
        my @vals = unpack('V*', substr($buf,0,$usable));
        for my $raw (@vals) {
            $samples_seen++;
            next if $raw == 0;
            $nonzero++;
            my $low8 = $raw & 0xFF;
            if ($low8 != 0) {
                # Ya no puede ser ni 24 efectivos ni 16 efectivos en 32.
                $exact24_possible = 0;
                $exact16_possible = 0;
                last;
            }
            my $low16 = $raw & 0xFFFF;
            $exact16_possible = 0 if $low16 != 0;
        }
        last if !$exact24_possible;
    }
}

# Si se leyó todo y no hubo ninguna muestra no-cero, es silencio digital.
# En una salida temprana esto no puede ocurrir, porque exige un LSB no-cero.
if (!$early_no_pattern && $remaining <= 0 && $nonzero == 0) {
    print_result(valid=>1,encoding=>'PCM ENTERO',container_bits=>$bits,valid_bits=>$valid_bits,
        strict=>'PROFUNDIDAD EFECTIVA NO DETERMINABLE - SILENCIO DIGITAL',pattern=>'NO APLICA',
        nonzero=>0,common_zero_lsb=>$bits,error=>'');
    exit 0;
}

my $strict;
my $common_zero_lsb = 0;
if ($bits == 24) {
    if (!$early_no_pattern && $exact16_possible) {
        $strict='16 BITS EFECTIVOS EN CONTENEDOR PCM DE 24';
        $common_zero_lsb = 8;
    } else {
        $strict='PCM 24 - SIN PATRON EXACTO DE 16 BITS';
    }
} else {
    if ($exact24_possible && $exact16_possible) {
        $strict='16 BITS EFECTIVOS EN CONTENEDOR PCM ENTERO DE 32';
        $common_zero_lsb = 16;
    }
    elsif ($exact24_possible) {
        $strict='24 BITS EFECTIVOS EN CONTENEDOR PCM ENTERO DE 32';
        $common_zero_lsb = 8;
    }
    else {
        $strict='PCM ENTERO 32 - SIN PATRON EXACTO DE 24/16 BITS';
    }
}

my ($pattern,$grid_exact_pct,$grid2_pct,$grid_rms,$res_entropy,$res_distinct) = ('NO APLICA','','','','','');
if ($bits == 24) {
    if ($early_no_pattern) {
        # La decisión es definitiva aunque no se hayan recorrido las muestras restantes.
        $pattern='SIN PATRON CLARO DE CUANTIZACION PREVIA DE 16 BITS';
    }
    elsif ($nonzero > 0) {
        $grid_exact_pct = 100.0*$grid_exact/$nonzero;
        $grid2_pct = 100.0*$grid2/$nonzero;
        $grid_rms = sqrt($grid_sq/$nonzero);
        $res_entropy = entropy_counts(\@res_counts,$nonzero);
        $res_distinct = 0; for my $c (@res_counts) { $res_distinct++ if $c; }

        if (!$exact16_possible) {
            my $strong = ($grid2_pct >= 95.0 && $grid_rms <= 2.0 && $res_entropy <= 3.0 && $res_distinct <= 32);
            my $partial = ($grid_exact_pct >= 90.0 && $res_entropy <= 1.5 && $grid_rms <= 5.0);
            if ($strong) { $pattern='PATRON FUERTEMENTE COMPATIBLE CON CUANTIZACION PREVIA DE 16 BITS'; }
            elsif ($partial) { $pattern='PATRON PARCIAL COMPATIBLE CON GRILLA DE 16 BITS'; }
            else { $pattern='SIN PATRON CLARO DE CUANTIZACION PREVIA DE 16 BITS'; }
        } else {
            $pattern='NO APLICA: PATRON EXACTO DE 16 BITS';
        }
    }
}

print_result(
    valid=>1, encoding=>'PCM ENTERO', container_bits=>$bits, valid_bits=>$valid_bits,
    strict=>$strict, pattern=>$pattern, nonzero=>$nonzero, common_zero_lsb=>$common_zero_lsb,
    grid_exact_pct=>($grid_exact_pct eq ''?'':sprintf('%.6f',$grid_exact_pct)),
    grid_within2_pct=>($grid2_pct eq ''?'':sprintf('%.6f',$grid2_pct)),
    grid_rms=>($grid_rms eq ''?'':sprintf('%.6f',$grid_rms)),
    grid_residual_entropy=>($res_entropy eq ''?'':sprintf('%.6f',$res_entropy)),
    grid_distinct_residuals=>$res_distinct, error=>''
);
