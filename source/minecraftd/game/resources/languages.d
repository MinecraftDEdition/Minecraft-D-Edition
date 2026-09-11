module minecraftd.game.resources.languages;

import std.file : exists, readText, write, mkdirRecurse, dirEntries, SpanMode, getSize;
import std.exception : enforce;
import std.path : buildPath, dirName, baseName, stripExtension;
import std.string : toLower, replace, split, splitLines, strip, startsWith, endsWith, indexOf;
import std.algorithm : sort, canFind;
import std.json : JSONValue, JSONType, parseJSON;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.process : environment;
import std.regex : matchFirst, ctRegex;
import minecraftd.game.resources.resource_packs : PackMount;
import minecraftd.game.resources.compatibility : modernTextureName;
version(Windows) private extern(Windows) int GetUserDefaultLocaleName(wchar*,int);

LanguageService activeLanguage;
string tr(string key,string fallback)
{return activeLanguage is null?fallback:activeLanguage.text(key,fallback);}
string translatedItem(string english)
{
    if(english=="Spawn Zombie")
    {
        const label=tr("item.minecraft.zombie_spawn_egg",english);
        return label=="Zombie Spawn Egg"?english:label;
    }
    return activeLanguage is null?english:activeLanguage.itemText(english);
}
string translatedLabel(string english)
{return activeLanguage is null?english:activeLanguage.labelText(english);}

string normalizeLanguage(string value)
{
    value=value.strip.toLower.replace("-","_");
    const dot=value.indexOf('.');if(dot>=0)value=value[0..dot];
    const at=value.indexOf('@');if(at>=0)value=value[0..at];
    if(value.startsWith("zh_hant"))return "zh_tw";
    if(value.startsWith("zh_hans"))return "zh_cn";
    return value;
}

string systemLanguage()
{
    version(Windows)
    {
        import std.utf : toUTF8;
        wchar[85] value;
        const count=GetUserDefaultLocaleName(value.ptr,85);
        if(count>1)return normalizeLanguage(toUTF8(value[0..count-1]));
    }
    else version(OSX)
    {
        import std.process : execute;
        try
        {
            const result=execute(["/usr/bin/defaults","read","-g","AppleLanguages"]);
            if(result.status==0)foreach(line;result.output.splitLines)
            {
                auto value=line.strip.replace("\"","").replace(",","");
                if(value!="("&&value!=")"&&value.length)return normalizeLanguage(value);
            }
        }catch(Exception){}
    }
    foreach(key;["LC_ALL","LC_MESSAGES","LANG"])
        if(environment.get(key,"").length)return normalizeLanguage(environment[key]);
    return "en_us";
}

string[string] readTranslations(string path)
{
    enforce(getSize(path)<=8*1024*1024,"Language file exceeds the 8 MiB limit");
    string[string] result;
    const content=readText(path);
    if(path.endsWith(".json"))
    {
        const json=parseJSON(content);
        if(json.type==JSONType.object)foreach(key,value;json.object)
            if(value.type==JSONType.string)result[key]=value.str;
    }
    else foreach(line;content.splitLines)
    {
        if(line.strip.startsWith("#"))continue;
        const equals=line.indexOf('=');
        if(equals>0)result[line[0..equals].strip]=line[equals+1..$];
    }
    auto original=result.dup;
    foreach(key,value;original)
    {
        const canonical=legacyTranslationKey(key);
        if(canonical!=key&&canonical !in result)result[canonical]=value;
    }
    return result;
}

string legacyTranslationKey(string key)
{
    if(!(key.startsWith("tile.")||key.startsWith("item."))||!key.endsWith(".name"))return key;
    const item=key.startsWith("item.");
    auto name=key[5..$-5];
    foreach(pair;"grass:grass_block stonebrick:cobblestone stonebricksmooth:stone_bricks stoneMoss:mossy_cobblestone wood:oak_planks reeds:sugar_cane lightgem:glowstone hellrock:netherrack whiteStone:end_stone waterlily:lily_pad".split())
    {const p=pair.split(":");if(name==p[0])return "block.minecraft."~p[1];}
    if(name.startsWith("stone."))
    {
        name=name[6..$];
        if(name.endsWith("Smooth"))name="polished_"~name[0..$-6];
        return "block.minecraft."~name;
    }
    const parts=name.split('.');
    if(parts.length==2)foreach(pair;"wood:planks log:log leaves:leaves sapling:sapling cloth:wool wool:wool stainedGlass:stained_glass stainedGlassPane:stained_glass_pane stainedHardenedClay:terracotta concrete:concrete concretePowder:concrete_powder".split())
    {
        const p=pair.split(":");
        if(parts[0]==p[0])return "block.minecraft."~parts[1].replace("big_oak","dark_oak").replace("silver","light_gray")~"_"~p[1];
    }
    if(item)foreach(kind;["sword","shovel","pickaxe","axe","hoe"])
        if(name.startsWith(kind)&&name.length>kind.length)
        {
            auto material=name[kind.length..$].toLower;
            if(material=="wood")material="wooden";if(material=="gold")material="golden";
            return "item.minecraft."~material~"_"~kind;
        }
    string snake;
    foreach(char c;name)
    {
        if(c=='.'){snake~='_';continue;}
        if(c>='A'&&c<='Z'){snake~='_';snake~=cast(char)(c+32);}else snake~=c;
    }
    return (item?"item.minecraft.":"block.minecraft.")~modernTextureName(snake,item);
}

struct LanguageEntry { string code,name; bool suppliedByPack; }

final class LanguageService
{
    LanguageEntry[] available;
    string selected="en_us", detected, context="default", notice;
    private string resources,settings;
    private string[string] choices,values,englishItems,englishUi;
    private PackMount[] mounts;

    this(string userRoot,string resourceRoot,string locale="")
    {
        resources=resourceRoot;settings=buildPath(userRoot,"data","languages.json");
        detected=normalizeLanguage(locale.length?locale:systemLanguage());
        if(exists(settings))try
        {
            const saved=parseJSON(readText(settings));
            foreach(key,value;saved.object)if(value.type==JSONType.string)choices[key]=value.str;
        }catch(Exception){notice="Saved language choices could not be read.";}
        configure([]);
    }

    private string chooseAvailable(string wanted,string[] codes) const
    {
        if(codes.canFind(wanted))return wanted;
        const family=wanted.split('_')[0];
        foreach(preferred;["en_us","es_es","fr_fr","de_de","pt_pt","zh_cn"])
            if(preferred.split('_')[0]==family&&codes.canFind(preferred))return preferred;
        foreach(code;codes)if(code.split('_')[0]==family)return code;
        return codes.canFind("en_us")?"en_us":codes.length?codes[0]:"en_us";
    }

    void configure(PackMount[] packs)
    {
        mounts=packs;notice="";
        string[][string] files;
        string[string] resourceKeys;
        const directory=buildPath(resources,"assets","minecraft","lang");
        if(exists(directory))foreach(entry;dirEntries(directory,SpanMode.shallow))
            if(entry.isFile&&(entry.name.endsWith(".json")||entry.name.endsWith(".lang")))
            {
                files[normalizeLanguage(stripExtension(baseName(entry.name)))]~=[entry.name];
                resourceKeys[entry.name]="minecraft/lang/"~baseName(entry.name);
            }
        string[] preferred;
        foreach_reverse(pack;packs)
        {
            foreach(code;files.keys)
            {
                string[] kept;
                foreach(path;files[code])
                {
                    const key=resourceKeys[path],slash=key.indexOf('/');
                    if(!pack.blocks(key[0..slash],key[slash+1..$]))kept~=path;
                }
                if(kept.length)files[code]=kept;else files.remove(code);
            }
            string[] supplied;
            auto keys=pack.files.keys;
            keys.sort!((a,b)=>a.endsWith(".json")==b.endsWith(".json")?a<b:!a.endsWith(".json"));
            foreach(key;keys)
            {
                const path=pack.files[key];
                const parts=key.split('/');
                if(parts.length!=3||parts[1]!="lang"||!(key.endsWith(".json")||key.endsWith(".lang")))continue;
                const code=normalizeLanguage(stripExtension(parts[2]));
                if(code !in files&&files.length>=512){notice="Only the first 512 languages are listed.";continue;}
                files[code]~=[path];supplied~=code;
                resourceKeys[path]=key;
            }
            if(supplied.length){supplied.sort();preferred=supplied;}
        }
        available=[];
        auto codes=files.keys;codes.sort();
        foreach(code;codes)
        {
            string name=code,regionName;
            foreach(path;files[code])try
            {
                if(path.endsWith(".json"))
                {
                    enforce(getSize(path)<=8*1024*1024,"Language file is too large");
                    const content=readText(path);
                    auto n=matchFirst(content,ctRegex!`"language.name"\s*:\s*("(?:[^"\\]|\\.)*")`);
                    auto region=matchFirst(content,ctRegex!`"language.region"\s*:\s*("(?:[^"\\]|\\.)*")`);
                    if(!n.empty)name=parseJSON(n.captures[1]).str;
                    if(!region.empty)regionName=parseJSON(region.captures[1]).str;
                }
                else
                {
                    const table=readTranslations(path);
                    if(auto n="language.name" in table)name=*n;
                    if(auto region="language.region" in table)regionName=*region;
                }
            }catch(Exception){notice="Some language files could not be read.";}
            if(regionName.length)name~=" ("~regionName~")";
            foreach_reverse(pack;packs)if(auto declared=code in pack.languageNames)name=*declared;
            available~=LanguageEntry(code,name,preferred.canFind(code));
        }
        string[] ids;foreach(pack;packs)ids~=pack.id;
        import std.json : JSONValue;
        context=preferred.length?toHexString(sha256Of(JSONValue(ids).toString())).idup:"default";
        string base=detected;
        if(auto choice="default" in choices)base=*choice;
        if(auto choice=context in choices)selected=chooseAvailable(*choice,codes);
        else selected=chooseAvailable(base,preferred.length?preferred:codes);
        values=null;englishItems=null;englishUi=null;
        const builtin=buildPath(directory,"en_us.json");
        if(exists(builtin))
        {
            auto table=readTranslations(builtin);auto keys=table.keys;keys.sort();
            foreach(key;keys)
            {
                const value=table[key];
                if(key.startsWith("item.")||key.startsWith("block."))englishItems[value]=key;
                if(key.startsWith("options.")||key.startsWith("soundCategory.")||key.startsWith("gui."))
                    if(!value.canFind('%')&&!key.canFind("narrat"))englishUi[value]=key;
            }
        }
        // Load fallback language, then selected language, merging per key.
        foreach(code;selected=="en_us"?["en_us"]:["en_us",selected])
            if(auto sources=code in files)foreach(path;*sources)try
            {foreach(key,value;readTranslations(path))values[key]=value;}
            catch(Exception){notice="Some language files could not be read.";}
    }

    void select(string code)
    {
        string[] codes;foreach(entry;available)codes~=entry.code;
        if(!codes.canFind(code))return;
        choices[context]=code;
        mkdirRecurse(dirName(settings));write(settings,JSONValue(choices).toString());
        configure(mounts);
    }
    void automatic()
    {
        choices.remove(context);mkdirRecurse(dirName(settings));
        write(settings,JSONValue(choices).toString());configure(mounts);
    }
    string text(string key,string fallback) const
    {if(auto value=key in values)return *value;return fallback;}
    string itemText(string english) const
    {if(auto key=english in englishItems)return text(*key,english);return english;}
    string labelText(string english) const
    {
        if(auto key=english in englishUi)return text(*key,english);
        const colon=english.indexOf(": ");
        if(colon>0)if(auto key=english[0..colon] in englishUi)
            return text(*key,english[0..colon])~": "~labelText(english[colon+2..$]);
        return english;
    }
    string glyphText() const
    {
        string result;foreach(value;values)result~=value;
        foreach(entry;available)result~=entry.name;
        return result;
    }
}
