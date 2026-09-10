module minecraftd.client.render.text_layout;
import std.utf : toUTF16,toUTF8;
import std.string : toStringz;

private alias Open=extern(C) void* function();
private alias Close=extern(C) void function(void*);
private alias Set=extern(C) void function(void*,const(wchar)*,int,ubyte,const(ubyte)*,int*);
private alias Write=extern(C) int function(void*,wchar*,int,ushort,int*);
private alias Shape=extern(C) int function(const(wchar)*,int,wchar*,int,uint,int*);
private Open bidiOpen;private Close bidiClose;private Set bidiSet;
private Write bidiWrite;private Shape arabicShape;
private bool initialized;
private string[string] cache;

private void initialize()
{
    if(initialized)return;initialized=true;
    void* library;
    version(Windows)
    {
        import core.sys.windows.windows : LoadLibraryExW,GetProcAddress,HMODULE;
        library=cast(void*)LoadLibraryExW("icu.dll"w.ptr,null,0x800);
        void* symbol(string name){return library?cast(void*)GetProcAddress(cast(HMODULE)library,name.toStringz):null;}
    }
    else version(OSX)
    {
        import core.sys.posix.dlfcn : dlopen,dlsym,RTLD_LAZY;
        library=dlopen("/usr/lib/libicucore.A.dylib".ptr,RTLD_LAZY);
        void* symbol(string name){return library?dlsym(library,name.toStringz):null;}
    }
    else {void* symbol(string name){return null;}}
    bidiOpen=cast(Open)symbol("ubidi_open");bidiClose=cast(Close)symbol("ubidi_close");
    bidiSet=cast(Set)symbol("ubidi_setPara");bidiWrite=cast(Write)symbol("ubidi_writeReordered");
    arabicShape=cast(Shape)symbol("u_shapeArabic");
}

/// Keep translations logically ordered in storage; reorder only for drawing.
string visualText(string text)
{
    bool rtl;
    foreach(dchar c;text)if(c>=0x590&&c<=0x8ff){rtl=true;break;}
    if(!rtl)return text;
    if(auto saved=text in cache)return *saved;
    initialize();if(!bidiOpen||!bidiClose||!bidiSet||!bidiWrite)return text;
    auto input=toUTF16(text);int error;
    if(arabicShape)
    {
        auto shaped=new wchar[input.length*2+8];
        // U_SHAPE_LETTERS_SHAPE, logical input, grow/shrink for ligatures.
        const count=arabicShape(input.ptr,cast(int)input.length,shaped.ptr,cast(int)shaped.length,8,&error);
        if(error<=0&&count>=0)input=shaped[0..count].idup;error=0;
    }
    auto bidi=bidiOpen();if(!bidi)return text;scope(exit)bidiClose(bidi);
    bidiSet(bidi,input.ptr,cast(int)input.length,0xfe,null,&error);
    if(error>0)return text;
    auto output=new wchar[input.length*2+8];
    const count=bidiWrite(bidi,output.ptr,cast(int)output.length,3,&error);
    if(error>0||count<0)return text;
    const result=toUTF8(output[0..count]);
    if(cache.length>=4096)cache=null;
    cache[text]=result;return result;
}

unittest
{
    assert(visualText("English 123")=="English 123");
    version(Windows)assert(visualText("אבג")=="גבא");
}
