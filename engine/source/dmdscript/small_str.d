/* Digital Mars DMDScript source code.
 * Distributed under the Boost Software License, Version 1.0.
 * (See accompanying file LICENSE_1_0.txt or copy at http://www.boost.org/LICENSE_1_0.txt)
 *
 * DMDScript is implemented in the D Programming Language,
 * http://www.digitalmars.com/d/
 *
 * Small string module - implements immutable UTF-16 string type
 * with said optimization and cache of hash code value.
 * 
 * Copyright: Dmitry Olshansky 2015-
 */

module dmdscript.small_str;

import core.memory;
import core.exception;

 // Immutable Wide (as in D's wstring) String
struct IWStr
{
private:
    static Big* allocBig(const(wchar)[] str, bool copy)
    {
        Big* ptr;
        if(copy)
        {
            ptr = cast(Big*)GC.malloc(str.length*wchar.sizeof + Big.sizeof);
            auto mut = (cast(wchar*)(ptr+1))[0..str.length];
            mut[] = str[]; // copy over the data
            ptr.data = cast(const(wchar)[])mut; // assume unique
        }
        else
        {
            ptr = cast(Big*)GC.malloc(Big.sizeof);
            ptr.data = str;
        }
        ptr.hash = 0;
        return ptr;
    }

    // "big" version layout
    static struct Big
    {
        const(wchar)[] data;
        uint hash;
    }
    // small version layout - must fit into 64-bit, a IEEE-754 double
    static struct Small
    {
    @nogc:
        enum maxLen = double.sizeof/2 - 1;
        wchar[maxLen] chars;
        ushort length_n_flag; // 15 bit of length + 1 bit flag of small vs big
        //
        @property size_t length() const { return length_n_flag >> 1; }
        //
        @property void length(size_t val){ length_n_flag = cast(ushort) ((val<<1) | 1); }
    }
    static assert(Small.sizeof == double.sizeof);
    version(LittleEndian)
    {
        union
        {
            Big* big;
            // lowest bit is set to 1 if small as lower bits of an aligned pointer are zero
            Small small;
        }
    }
    else
    {
        // TODO: I don't have BigEndian machine, so no wrong code folks
        static assert(false, "Not implemented for BigEndian");
    }

    @nogc 
    @property bool isSmall()() const { return small.length_n_flag & 1; }
    @nogc pure
    static uint calcHash(const(wchar)[] s)
    {
        uint hash;
        /* If it looks like an array index, hash it to the
         * same value as if it was an array index.
         * This means that "1234" hashes to the same value as 1234.
         */
        hash = 0;
        foreach(wchar c; s)
        {
            switch(c)
            {
            case '0':       hash *= 10;             break;
            case '1':       hash = hash * 10 + 1;   break;

            case '2':
            case '3':
            case '4':
            case '5':
            case '6':
            case '7':
            case '8':
            case '9':
                hash = hash * 10 + (c - '0');
                break;

            default:
                {
                    //TODO: just use Murmur3 hash or smth
                    size_t len = s.length;
                    auto str = cast(const(ushort)*)s.ptr;
                    hash = 0;
                    assert(len != 0);
                    while(1)
                    {
                      switch(len)
                      {
                      case 1:
                          hash *= 9;
                          hash += *cast(ushort *)str;
                          break;

                      case 2:
                          hash *= 9;
                          hash += *cast(uint *)str;
                          break;

                      default:
                          hash *= 9;
                          hash += *cast(uint *)str;
                          str += 2;
                          len -= 2;
                          continue;
                      }
                      break;
                    }
                }
                return hash;
            }
        }
        return hash ^ 0x55555555;
    }

    alias This = typeof(this);
public:
    // make GC-dup of passed in slice
    static auto copyOf(const(wchar)[] value)
    {
        This str = void;
        if(value.length <= Small.maxLen)
        {
            str.small.length = value.length; // go from null ptr big to 0-sized small string
            str.small.chars[0..value.length] = value[];
        }
        else
        {
            str.big = allocBig(value, true); // allocate with extra space for chars
        }
        return str;
    }

    // constructor just takes a slice
    this(const(wchar)[] value)
    {
        if(value.length <= Small.maxLen)
        {
            small.length = value.length; // go from null ptr big to 0-sized small string
            small.chars[0..value.length] = value[];
        }
        else
        {
            big = allocBig(value, false); // allocate w/o extra space
        }
    }

    auto opBinary(string op:"~")(const This rhs)
    {
        immutable len = length, rlen = rhs.length;
        immutable total = len + rlen;
        This str=void;
        if(total <= Small.maxLen)
        {
            str.small.length = total;
            str.small.chars[0..len] = small.chars[0..len];
            str.small.chars[len..total] = rhs.small.chars[0..rlen];
        }
        else
        {
            str = This(this[] ~ rhs[]);
        }
        return str;
    }

@nogc:
    size_t length() const
    {
        return isSmall ? small.length : big.data.length;
    }

    static struct Pair(T)
    {
        T a,b;
    }

    wchar opIndex(size_t idx) const
    {
        return isSmall ? small.chars[idx] : big.data[idx];
    }

    Pair!size_t opSlice(size_t dim)(size_t a, size_t b) if(dim == 0)
    {
        return Pair!size_t(a, b);
    }
    
    const(wchar)[] opIndex(Pair!size_t range) const
    {
        if(isSmall)
            return small.chars[range.a..range.b];
        else
            return big.data[range.a..range.b];
    }
    
    const(wchar)[] opIndex() const
    {
        return isSmall ? small.chars[0..small.length] : big.data;
    }

    bool opEquals(const This other) const
    {
        return this[] == other[];
    }

    bool opEquals(const(wchar)[] rhs) const
    {
        return this[] == rhs;
    }

    uint toHash()
    {
        if(isSmall)
            return calcHash(small.chars[0..small.length]);
        if(big.hash)
            return big.hash;
        else
            return big.hash = calcHash(big.data[]);
    }
}

unittest
{
    auto a = IWStr.copyOf("abc"), b = IWStr.copyOf("d"), c = IWStr.copyOf("ef");
    assert(a[2] == 'c');
    assert(a[1..2] == "b");
    assert(b[0] == 'd');
    assert(c[1] == 'f');
    assert(c[0..2] == "ef");
    auto d = IWStr("GHI4"), y = IWStr.copyOf("Строка!");
    assert(d[3] == '4');
    auto ab = a ~ b;
    assert(ab[] == "abcd"w);
    auto x = ab;
    assert(x ~ y == "abcdСтрока!");
    assert(y[1..4] == "тро");
    assert(y[4] == 'к');
    assert(x == "abcd");
    assert(b ~ c == "def");
    assert(b ~ a == "dabc");
    assert(d ~ ab == "GHI4abcd");
    // Hash must be revised anyway
    auto num = IWStr("12345");
    assert(num.toHash() == (12345 ^ 0x55555555));
    assert(num.toHash() == (12345 ^ 0x55555555)); // cached
    auto small_num = IWStr("907");
    assert(small_num.toHash() == (907 ^ 0x55555555));
    assert(a.toHash() == ('b'*2^^16 + 'a')*9 +'c');
    assert(d.toHash() == ('H'*2^^16 + 'G')*9 + '4'*2^^16 + 'I');
    assert(IWStr("").toHash() == 0x55555555);
}
