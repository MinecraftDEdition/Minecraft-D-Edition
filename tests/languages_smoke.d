module languages_smoke;
import std.file;
import std.path;
import std.uuid : randomUUID;
import std.stdio : writeln;
import minecraftd.game.resources.languages;
import minecraftd.game.resources.resource_packs : PackMount;

void main()
{
    const root=buildPath(tempDir(),"mde-languages-"~randomUUID().toString());
    mkdirRecurse(buildPath(root,"assets","minecraft","lang"));
    scope(exit)rmdirRecurse(root);
    const lang=buildPath(root,"assets","minecraft","lang");
    write(buildPath(lang,"en_us.json"),`{"language.name":"English","menu.singleplayer":"Singleplayer","menu.quit":"Quit Game","block.minecraft.stone":"Stone"}`);
    write(buildPath(lang,"fr_fr.json"),`{"language.name":"Français","menu.singleplayer":"Solo"}`);
    auto service=new LanguageService(root,root,"fr-CA");
    assert(service.selected=="fr_fr");
    assert(service.text("menu.singleplayer","")=="Solo");
    assert(service.text("menu.quit","")=="Quit Game");
    service.select("en_us");
    auto restored=new LanguageService(root,root,"fr-FR");
    assert(restored.selected=="en_us");
    restored.select("fr_fr");
    const packLang=buildPath(root,"pack.lang");
    write(packLang,"# old Java pack\nmenu.singleplayer=Custom=English\ntile.stone.stone.name=Rock\nitem.swordWood.name=Stick\n");
    PackMount a;a.id="A";a.files["minecraft/lang/en_us.lang"]=packLang;
    restored.configure([a]);
    assert(restored.selected=="en_us");
    assert(restored.text("menu.singleplayer","")=="Custom=English");
    assert(restored.itemText("Stone")=="Rock");
    assert(restored.text("item.minecraft.wooden_sword","")=="Stick");
    restored.select("fr_fr");
    restored.configure([]);assert(restored.selected=="fr_fr");
    restored.select("en_us");
    restored.configure([a]);assert(restored.selected=="fr_fr");
    const modern=buildPath(root,"pack.json");
    write(modern,`{"menu.singleplayer":"Modern wins"}`);
    a.files["minecraft/lang/en_us.json"]=modern;
    restored.configure([a]);restored.select("en_us");
    assert(restored.text("menu.singleplayer","")=="Modern wins");
    PackMount b;b.id="B";b.files["minecraft/lang/fr_fr.json"]=buildPath(lang,"fr_fr.json");
    restored.configure([b]);assert(restored.selected=="fr_fr");
    restored.configure([a]);assert(restored.selected=="en_us");
    assert(normalizeLanguage("de-DE.UTF-8")=="de_de");
    writeln("Locale detection fallback, saved choices, pack restoration, JSON/lang overrides and legacy keys passed");
}
