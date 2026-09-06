/* ------------------------------------------------------------------------ */
/* LHa for UNIX                                                             */
/*              bitio.c -- bit stream                                       */
/*                                                                          */
/*      Modified                Nobutaka Watazaki                           */
/*                                                                          */
/*  Ver. 1.14   Source All chagned              1995.01.14  N.Watazaki      */
/*              Separated from crcio.c          2002.10.26  Koji Arai       */
/* ------------------------------------------------------------------------ */
#include "lha.h"

static unsigned char subbitbuf, bitcount;

void
fillbuf(unsigned char n)  /* Shift bitbuf n bits left, read n bits */
{
    while (n > bitcount) {
        n -= bitcount;
        // 原版は入力境界でゼロを補わず、直前の残余バイトを繰り返す。
        subbitbuf >>= CHAR_BIT - bitcount;
        bitbuf = (bitbuf << bitcount) + subbitbuf;
        Lha_ConsumeProgressDecoderByte();
        if (compsize != 0) {
            int c = getc(infile);
            compsize--;
            if (c == EOF) {
                fatal_error("cannot read stream");
            }
            subbitbuf = (unsigned char)c;
        }
        bitcount = CHAR_BIT;
    }
    bitcount -= n;
    bitbuf = (bitbuf << n) + (subbitbuf >> (CHAR_BIT - n));
    subbitbuf <<= n;
}

unsigned short
getbits(unsigned char n)
{
    unsigned short  x;

    x = bitbuf >> (2 * CHAR_BIT - n);
    fillbuf(n);
    return x;
}

void
putcode(unsigned char n, unsigned short x)  /* Write leftmost n bits of x */
{
    while (n >= bitcount) {
        n -= bitcount;
        subbitbuf += x >> (USHRT_BIT - bitcount);
        x <<= bitcount;
        if (compsize < origsize) {
            if (Lha_WriteCompressionData(&subbitbuf, 1, 1, outfile) == 0) {
                fatal_error("Write error in bitio.c(putcode)");
            }
            compsize++;
        }
        else
            unpackable = 1;
        subbitbuf = 0;
        bitcount = CHAR_BIT;
    }
    subbitbuf += x >> (USHRT_BIT - bitcount);
    bitcount -= n;
}

void
putbits(unsigned char n, unsigned short x)  /* Write rightmost n bits of x */
{
    x <<= USHRT_BIT - n;
    putcode(n, x);
}

void
init_getbits( /* void */ )
{
    bitbuf = 0;
    subbitbuf = 0;
    bitcount = 0;
    fillbuf(2 * CHAR_BIT);
}

void
init_putbits( /* void */ )
{
    bitcount = CHAR_BIT;
    subbitbuf = 0;
}
