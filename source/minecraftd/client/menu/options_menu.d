module minecraftd.client.menu.options_menu;

import std.conv : ConvException, to;
import std.file : exists, readText, write;
import std.format : format;
import std.path : buildPath;
import std.string : indexOf, splitLines, strip;

import minecraftd.client.render.font_renderer : FontRenderer;
import minecraftd.client.render.mesh : Color, DrawLayer, FrameMesh, Vertex, appendQuad;
import minecraftd.common.math3d : Mat4, Vec2, Vec3, clamp;

enum OptionsScreen : ubyte
{
    main, online, skin, sounds, video, controls, mouse, keyBinds,
    keyboardMouse, controller, language, font, chat, resourcePacks,
    accessibility, telemetry, credits,
}

final class OptionsMenuRenderer
{
    OptionsAction hitTest(uint viewportWidth,uint viewportHeight,int mouseX,
        int mouseY,const OptionsMenuState state) const
    {
        const scale=guiScale(viewportWidth,viewportHeight);
        const width=cast(int)viewportWidth/scale, height=cast(int)viewportHeight/scale;
        foreach(spec;widgetsFor(state))
        {
            if(spec.action==OptionsAction.none || !spec.enabled
                || spec.kind==WidgetKind.heading || spec.kind==WidgetKind.display) continue;
            const area=widgetRect(spec,width,height,state);
            if((spec.row==100 || (area.y>=contentTop(state.screen)
                && area.y+area.height<=height-32))
                && area.contains(mouseX/scale,mouseY/scale)) return spec.action;
        }
        return OptionsAction.none;
    }

    void append(ref FrameMesh frame,uint viewportWidth,uint viewportHeight,
        int mouseX,int mouseY,const OptionsMenuState state,bool worldBehind,
        const OptionsTextureSet textures,const FontRenderer font,uint fontTexture) const
    {
        const scale=guiScale(viewportWidth,viewportHeight);
        const width=cast(float)viewportWidth/scale,height=cast(float)viewportHeight/scale;
        const hovered=hitTest(viewportWidth,viewportHeight,mouseX,mouseY,state);
        if(worldBehind) rect(frame,textures.white,0,0,cast(int)width,cast(int)height,
            width,height,Color(0,0,0,.58f));
        else tiledBackground(frame,textures.menuBackground,width,height);
        centered(frame,screenTitle(state.screen),8,width,height,font,fontTexture,Color(1,1,1,1));
        foreach(spec;widgetsFor(state))
        {
            const area=widgetRect(spec,cast(int)width,cast(int)height,state);
            if(spec.row!=100 && (area.y<contentTop(state.screen)
                || area.y+area.height>cast(int)height-32)) continue;
            if(spec.kind==WidgetKind.heading)
            {
                text(frame,spec.fixedLabel,area.x,area.y+6,width,height,font,fontTexture,Color(1,1,1,1));
                continue;
            }
            const value=spec.fixedLabel.length?spec.fixedLabel:label(spec.action,state);
            if(spec.kind==WidgetKind.slider)
                sliderButton(frame,area,value,sliderAmount(spec.action,state),
                    hovered==spec.action,width,height,textures,font,fontTexture);
            else button(frame,area,value,hovered==spec.action,
                spec.enabled&&spec.kind!=WidgetKind.display,width,height,textures,font,fontTexture);
        }
        appendScrollBar(frame,state,cast(int)width,cast(int)height,textures);
    }

private:
    static void appendScrollBar(ref FrameMesh frame,const OptionsMenuState state,
        int width,int height,const OptionsTextureSet textures)
    {
        const maximum=maximumScrollRow(cast(uint)width,cast(uint)height,state,true);
        if(maximum<=0)return;
        const top=contentTop(state.screen), trackHeight=height-top-34, x=width/2+158;
        rect(frame,textures.white,x,top,3,trackHeight,width,height,Color(0,0,0,.7f));
        const thumbHeight=clampInt(trackHeight/(maximum+1),10,trackHeight);
        const thumbY=top+cast(int)((trackHeight-thumbHeight)*(cast(float)state.scrollRow/maximum));
        rect(frame,textures.white,x,thumbY,3,thumbHeight,width,height,Color(.75f,.75f,.75f,1));
    }
    static void sliderButton(ref FrameMesh frame,OptionRect area,string value,
        float amount,bool highlighted,float width,float height,
        const OptionsTextureSet textures,const FontRenderer font,uint fontTexture)
    {
        rect(frame,highlighted?textures.buttonHighlighted:textures.button,
            area.x,area.y,area.width,area.height,width,height,Color(1,1,1,1));
        const knobX=area.x+2+cast(int)(clamp(amount,0,1)*(area.width-8));
        rect(frame,textures.white,knobX,area.y+2,6,area.height-4,width,height,Color(1,1,1,.75f));
        text(frame,value,area.x+(area.width-font.width(value))/2,area.y+6,
            width,height,font,fontTexture,highlighted?Color(1,1,.63f,1):Color(1,1,1,1));
    }
    static void button(ref FrameMesh frame,OptionRect area,string value,
        bool highlighted,bool enabled,float width,float height,
        const OptionsTextureSet textures,const FontRenderer font,uint fontTexture)
    {
        const texture=!enabled?textures.buttonDisabled:(highlighted?textures.buttonHighlighted:textures.button);
        rect(frame,texture,area.x,area.y,area.width,area.height,width,height,Color(1,1,1,1));
        const color=!enabled?Color(.63f,.63f,.63f,1):(highlighted?Color(1,1,.63f,1):Color(1,1,1,1));
        text(frame,value,area.x+(area.width-font.width(value))/2,area.y+6,width,height,font,fontTexture,color);
    }
    static void centered(ref FrameMesh frame,string value,int y,float width,
        float height,const FontRenderer font,uint texture,Color color)
    { text(frame,value,(cast(int)width-font.width(value))/2,y,width,height,font,texture,color); }
    static void text(ref FrameMesh frame,string value,int x,int y,float width,
        float height,const FontRenderer font,uint texture,Color color)
    { frame.append(font.buildText(value,x,y,width,height,color),texture,Mat4.identity(),DrawLayer.overlay); }
    static void rect(ref FrameMesh frame,uint texture,int x,int y,int rectWidth,
        int rectHeight,float viewportWidth,float viewportHeight,Color color)
    {
        Vertex[] geometry;
        appendQuad(geometry,Vec3(x,y,0),Vec3(x,y+rectHeight,0),
            Vec3(x+rectWidth,y+rectHeight,0),Vec3(x+rectWidth,y,0),
            Vec2(0,0),Vec2(0,1),Vec2(1,1),Vec2(1,0),color,color,color,color);
        frame.append(geometry,texture,pixelProjection(viewportWidth,viewportHeight),DrawLayer.overlay);
    }
    static void tiledBackground(ref FrameMesh frame,uint texture,float width,float height)
    {
        Vertex[] geometry; const color=Color(.45f,.45f,.45f,1);
        appendQuad(geometry,Vec3(0,0,0),Vec3(0,height,0),Vec3(width,height,0),
            Vec3(width,0,0),Vec2(0,0),Vec2(0,height/32),Vec2(width/32,height/32),
            Vec2(width/32,0),color,color,color,color);
        frame.append(geometry,texture,pixelProjection(width,height),DrawLayer.overlay);
    }
    static Mat4 pixelProjection(float width,float height)
    {
        Mat4 result=Mat4.identity(); result.m[0]=2/width; result.m[5]=-2/height;
        result.m[12]=-1; result.m[13]=1; return result;
    }
}

enum OptionsAction : ushort
{
    none, done, fov,
    onlineMenu, skinMenu, soundsMenu, videoMenu, controlsMenu, languageMenu,
    chatMenu, resourcePacksMenu, accessibilityMenu, telemetryMenu, creditsMenu,
    mouseMenu, keyBindsMenu, keyboardMouseMenu, controllerMenu, fontMenu,
    friendsList, allowFriendRequests, inGameNotification, sharePresence,
    xboxSettings, allowServerListing, realmsNotifications,
    cape, jacket, leftSleeve, rightSleeve, leftPantLeg, rightPantLeg, hat, mainHand,
    masterVolume, musicVolume, recordVolume, weatherVolume, soundVolume,
    hostileVolume, neutralVolume, playerVolume, ambientVolume, voiceVolume,
    uiVolume, audioDevice, subtitles, directionalAudio, musicFrequency, musicToast,
    fullscreenResolution, maxFramerate, vsync, inactivityFpsLimit, guiScale,
    fullscreen, exclusiveFullscreen, brightness, graphicsApi, graphicsPreset,
    biomeBlend, renderDistance, chunkBuilder, simulationDistance, smoothLighting,
    clouds, particles, mipmapLevels, entityShadows, entityDistance,
    menuBackgroundBlur, cloudDistance, cutoutLeaves, improvedTransparency,
    textureFiltering, anisotropicFiltering, weatherRadius, autosaveIndicator,
    vignette, attackIndicator, chunkFade,
    sneakMode, sprintMode, attackMode, useMode, autoJump, sprintWindow,
    operatorItemsTab, sensitivity, scrollSensitivity, discreteScrolling,
    invertMouseX, invertMouseY, allowCursorChanges, rawInput, resetKeys,
    bindForward, bindBack, bindLeft, bindRight, bindJump, bindSneak,
    bindSprint, bindAttack, bindUse, bindPickBlock, bindDrop, bindInventory, bindChat,
    bindFriends, bindPerspective, bindHotbar1, bindHotbar2, bindHotbar3,
    bindHotbar4, bindHotbar5, bindHotbar6, bindHotbar7, bindHotbar8,
    bindHotbar9,
    selectedLanguage, forceUnicodeFont, japaneseGlyphVariants,
    chatVisibility, chatColors, webLinks, promptLinks, chatOpacity,
    textBackgroundOpacity, chatScale, lineSpacing, chatDelay, chatWidth,
    focusedHeight, unfocusedHeight, narrator, commandSuggestions,
    hideMatchedNames, reducedDebugInfo, secureChat, saveUnsentChats,
    highContrast, textBackgroundMode, notificationTime, viewBobbing,
    distortionEffects, fovEffects, darknessPulsing, damageTilt, glintSpeed,
    glintStrength, hideSkyFlashes, monochromeLogo, panoramaSpeed,
    hideSplashTexts, narratorHotkey, rotateWithMinecarts,
    highContrastBlockOutlines, openPackFolder, telemetryCollection,
    showCredits, showAttribution, showLicensing,
}

struct OptionsTextureSet
{
    uint button, buttonHighlighted, buttonDisabled, white, menuBackground;
}

private enum WidgetKind : ubyte { button, slider, heading, display }

private struct OptionRect
{
    int x, y, width, height;
    bool contains(int px, int py) const
    { return px >= x && px < x + width && py >= y && py < y + height; }
}

private struct WidgetSpec
{
    OptionsAction action;
    int row, column;
    bool fullWidth, enabled;
    WidgetKind kind;
    string fixedLabel;
}

/// Persistent Java-shaped client preferences. Unknown key:value entries are
/// retained so additions remain forward compatible.
final class OptionsMenuState
{
    float fov = 70, mouseSensitivity = 1, masterVolume = 1, soundVolume = 1;
    bool fullscreen = true, viewBobbing = true, clouds = true;
    bool entityShadows = true, invertMouse, invertMouseX;
    bool allowCursorChanges = true;
    bool active, fromGame;
    OptionsScreen screen = OptionsScreen.main;
    int scrollRow;
    OptionsAction bindingCapture;

    private string storagePath;
    private string[string] extra;
    private OptionsScreen[] history;

    this(string projectRoot)
    {
        storagePath = buildPath(projectRoot, "data", "options.txt");
        load();
        constrain();
    }

    void open(bool game)
    {
        active = true; fromGame = game; screen = OptionsScreen.main;
        scrollRow = 0; history.length = 0; bindingCapture = OptionsAction.none;
    }

    void close()
    {
        active = false; screen = OptionsScreen.main; scrollRow = 0;
        history.length = 0; bindingCapture = OptionsAction.none; save();
    }

    void back()
    {
        if (history.length == 0) close();
        else
        {
            screen = history[$-1]; history.length = history.length-1;
            scrollRow = 0; save();
        }
    }

    void scroll(int wheelSteps, uint width, uint height)
    {
        if (screen == OptionsScreen.main || wheelSteps == 0) return;
        scrollRow = clampInt(scrollRow - wheelSteps, 0,
            maximumScrollRow(width, height, this));
    }

    bool slider(OptionsAction a) const
    {
        switch (a)
        {
            case OptionsAction.fov, OptionsAction.masterVolume,
                 OptionsAction.musicVolume, OptionsAction.recordVolume,
                 OptionsAction.weatherVolume, OptionsAction.soundVolume,
                 OptionsAction.hostileVolume, OptionsAction.neutralVolume,
                 OptionsAction.playerVolume, OptionsAction.ambientVolume,
                 OptionsAction.voiceVolume, OptionsAction.uiVolume,
                 OptionsAction.maxFramerate, OptionsAction.brightness,
                 OptionsAction.biomeBlend, OptionsAction.renderDistance,
                 OptionsAction.simulationDistance, OptionsAction.mipmapLevels,
                 OptionsAction.entityDistance, OptionsAction.menuBackgroundBlur,
                 OptionsAction.cloudDistance, OptionsAction.anisotropicFiltering,
                 OptionsAction.weatherRadius, OptionsAction.chunkFade,
                 OptionsAction.sprintWindow, OptionsAction.sensitivity,
                 OptionsAction.scrollSensitivity, OptionsAction.chatOpacity,
                 OptionsAction.textBackgroundOpacity, OptionsAction.chatScale,
                 OptionsAction.lineSpacing, OptionsAction.chatDelay,
                 OptionsAction.chatWidth, OptionsAction.focusedHeight,
                 OptionsAction.unfocusedHeight, OptionsAction.notificationTime,
                 OptionsAction.distortionEffects, OptionsAction.fovEffects,
                 OptionsAction.darknessPulsing, OptionsAction.damageTilt,
                 OptionsAction.glintSpeed, OptionsAction.glintStrength,
                 OptionsAction.panoramaSpeed: return true;
            default: return false;
        }
    }

    bool isBindingAction(OptionsAction a) const
    {
        return a >= OptionsAction.bindForward && a <= OptionsAction.bindHotbar9;
    }

    int key(OptionsAction binding) const
    {
        return integer(bindingKey(binding), defaultBinding(binding));
    }

    void captureKey(int virtualKey)
    {
        if (!isBindingAction(bindingCapture)) return;
        setInt(bindingKey(bindingCapture),virtualKey);
        bindingCapture = OptionsAction.none;
        save();
    }

    void cancelBindingCapture() { bindingCapture = OptionsAction.none; }

    ubyte skinParts() const
    {
        ubyte result;
        if(boolean("modelPart_hat",true))result|=1<<0;
        if(boolean("modelPart_jacket",true))result|=1<<1;
        if(boolean("modelPart_rightSleeve",true))result|=1<<2;
        if(boolean("modelPart_leftSleeve",true))result|=1<<3;
        if(boolean("modelPart_rightPantLeg",true))result|=1<<4;
        if(boolean("modelPart_leftPantLeg",true))result|=1<<5;
        return result;
    }

    bool mainHandRight() const { return integer("mainHand",1)==1; }

    void adjustSlider(OptionsAction a, int mouseX, uint width, uint height)
    {
        const scale = guiScale(width, height);
        OptionRect area;
        bool found;
        foreach (spec; widgetsFor(this)) if (spec.action == a)
        {
            area = widgetRect(spec, cast(int)width/scale, cast(int)height/scale, this);
            found = true; break;
        }
        if (!found || area.width <= 8) return;
        const value = clamp(cast(float)(mouseX/scale-area.x-4)/(area.width-8), 0, 1);
        switch (a)
        {
            case OptionsAction.fov: fov = 30 + value*80; break;
            case OptionsAction.sensitivity: mouseSensitivity = .25f + value*1.75f; break;
            case OptionsAction.masterVolume: masterVolume = value; break;
            case OptionsAction.soundVolume: soundVolume = value; break;
            case OptionsAction.musicVolume: setFloat("soundCategory_music",value); break;
            case OptionsAction.recordVolume: setFloat("soundCategory_record",value); break;
            case OptionsAction.weatherVolume: setFloat("soundCategory_weather",value); break;
            case OptionsAction.hostileVolume: setFloat("soundCategory_hostile",value); break;
            case OptionsAction.neutralVolume: setFloat("soundCategory_neutral",value); break;
            case OptionsAction.playerVolume: setFloat("soundCategory_player",value); break;
            case OptionsAction.ambientVolume: setFloat("soundCategory_ambient",value); break;
            case OptionsAction.voiceVolume: setFloat("soundCategory_voice",value); break;
            case OptionsAction.uiVolume: setFloat("soundCategory_ui",value); break;
            case OptionsAction.maxFramerate: setInt("maxFps",10+cast(int)(value*250)); break;
            case OptionsAction.brightness: setFloat("gamma",value); break;
            case OptionsAction.biomeBlend: setInt("biomeBlendRadius",cast(int)(value*7)*2+1); break;
            case OptionsAction.renderDistance: setInt("renderDistance",2+cast(int)(value*30)); break;
            case OptionsAction.simulationDistance: setInt("simulationDistance",5+cast(int)(value*27)); break;
            case OptionsAction.mipmapLevels: setInt("mipmapLevels",cast(int)(value*4)); break;
            case OptionsAction.entityDistance: setFloat("entityDistanceScaling",.5f+value*4.5f); break;
            case OptionsAction.menuBackgroundBlur: setInt("menuBackgroundBlurriness",cast(int)(value*10)); break;
            case OptionsAction.cloudDistance: setInt("renderCloudsDistance",32+cast(int)(value*96)); break;
            case OptionsAction.anisotropicFiltering: setInt("maxAnisotropy",1+cast(int)(value*15)); break;
            case OptionsAction.weatherRadius: setInt("weatherRadius",1+cast(int)(value*31)); break;
            case OptionsAction.chunkFade: setFloat("chunkFade",value*5); break;
            case OptionsAction.sprintWindow: setInt("sprintWindow",1+cast(int)(value*19)); break;
            case OptionsAction.scrollSensitivity: setFloat("mouseWheelSensitivity",.01f+value*9.99f); break;
            case OptionsAction.chatOpacity: setFloat("chatOpacity",value); break;
            case OptionsAction.textBackgroundOpacity: setFloat("textBackgroundOpacity",value); break;
            case OptionsAction.chatScale: setFloat("chatScale",value); break;
            case OptionsAction.lineSpacing: setFloat("chatLineSpacing",value); break;
            case OptionsAction.chatDelay: setFloat("chatDelay",value*6); break;
            case OptionsAction.chatWidth: setFloat("chatWidth",value); break;
            case OptionsAction.focusedHeight: setFloat("chatHeightFocused",value); break;
            case OptionsAction.unfocusedHeight: setFloat("chatHeightUnfocused",value); break;
            case OptionsAction.notificationTime: setFloat("notificationTime",.5f+value*4.5f); break;
            case OptionsAction.distortionEffects: setFloat("screenEffectScale",value); break;
            case OptionsAction.fovEffects: setFloat("fovEffectScale",value); break;
            case OptionsAction.darknessPulsing: setFloat("darknessEffectScale",value); break;
            case OptionsAction.damageTilt: setFloat("damageTiltStrength",value); break;
            case OptionsAction.glintSpeed: setFloat("glintSpeed",value); break;
            case OptionsAction.glintStrength: setFloat("glintStrength",value); break;
            case OptionsAction.panoramaSpeed: setFloat("panoramaSpeed",value); break;
            default: return;
        }
        save();
    }

    void activate(OptionsAction a)
    {
        const destination = destinationScreen(a);
        if (destination != OptionsScreen.main || a == OptionsAction.onlineMenu)
        { history ~= screen; screen = destination; scrollRow = 0; return; }
        switch (a)
        {
            case OptionsAction.done: back(); return;
            case OptionsAction.fullscreen: fullscreen = !fullscreen; break;
            case OptionsAction.viewBobbing: viewBobbing = !viewBobbing; break;
            case OptionsAction.clouds:
                setInt("renderClouds",(integer("renderClouds",2)+1)%3);
                setInt("graphicsPreset",3);
                clouds = integer("renderClouds",2) != 0; break;
            case OptionsAction.entityShadows:
                entityShadows = !entityShadows;
                setInt("graphicsPreset",3);
                break;
            case OptionsAction.invertMouseX: invertMouseX = !invertMouseX; break;
            case OptionsAction.invertMouseY: invertMouse = !invertMouse; break;
            case OptionsAction.allowCursorChanges: allowCursorChanges = !allowCursorChanges; break;
            case OptionsAction.graphicsPreset:
                const currentPreset=integer("graphicsPreset",1);
                const preset=currentPreset==3?0:(currentPreset+1)%3;
                setInt("graphicsPreset",preset);
                setInt("ao",preset==0?0:2);
                setInt("renderClouds",preset==0?1:2);
                setInt("particles",preset==0?1:0);
                entityShadows=preset!=0;
                clouds=true;
                break;
            case OptionsAction.smoothLighting, OptionsAction.particles:
                const intKey=integerKey(a);
                setInt(intKey,(integer(intKey,defaultInteger(a))+1)%choiceCount(a));
                setInt("graphicsPreset",3);
                break;
            case OptionsAction.resetKeys:
                foreach (value; cast(int)OptionsAction.bindForward
                    .. cast(int)OptionsAction.bindHotbar9+1)
                    extra.remove(bindingKey(cast(OptionsAction)value));
                bindingCapture = OptionsAction.none;
                break;
            case OptionsAction.openPackFolder,
                 OptionsAction.xboxSettings, OptionsAction.showCredits,
                 OptionsAction.showAttribution, OptionsAction.showLicensing,
                 OptionsAction.selectedLanguage, OptionsAction.audioDevice,
                 OptionsAction.fullscreenResolution, OptionsAction.exclusiveFullscreen,
                 OptionsAction.graphicsApi: break;
            default:
                if (isBindingAction(a))
                {
                    bindingCapture = a;
                    return;
                }
                const boolKey = booleanKey(a);
                if (boolKey.length) setBool(boolKey,!boolean(boolKey,defaultBoolean(a)));
                else
                {
                    const intKey = integerKey(a);
                    if (intKey.length) setInt(intKey,(integer(intKey,defaultInteger(a))+1)%choiceCount(a));
                }
                break;
        }
        save();
    }

    void save()
    {
        string data = format("fov:%s\nmouseSensitivity:%s\nmasterVolume:%s\n"
            ~"soundVolume:%s\nfullscreen:%s\nviewBobbing:%s\nclouds:%s\n"
            ~"entityShadows:%s\ninvertMouseX:%s\ninvertMouseY:%s\n"
            ~"allowCursorChanges:%s\n",fov,mouseSensitivity,masterVolume,
            soundVolume,fullscreen,viewBobbing,clouds,entityShadows,
            invertMouseX,invertMouse,allowCursorChanges);
        foreach (key; extra.keys) data ~= key~":"~extra[key]~"\n";
        try write(storagePath,data); catch (Exception) {}
    }

    float number(string key, float fallback) const
    {
        auto p=key in extra; if (p is null) return fallback;
        try return to!float(*p); catch (ConvException) return fallback;
    }
    int integer(string key, int fallback) const
    {
        auto p=key in extra; if (p is null) return fallback;
        try return to!int(*p); catch (ConvException) return fallback;
    }
    bool boolean(string key, bool fallback) const
    {
        auto p=key in extra; if (p is null) return fallback;
        try return to!bool(*p); catch (ConvException) return fallback;
    }

private:
    void setFloat(string key,float value){extra[key]=to!string(value);}
    void setInt(string key,int value){extra[key]=to!string(value);}
    void setBool(string key,bool value){extra[key]=to!string(value);}
    void constrain()
    {
        fov=clamp(fov,30,110); mouseSensitivity=clamp(mouseSensitivity,.25f,2);
        masterVolume=clamp(masterVolume,0,1); soundVolume=clamp(soundVolume,0,1);
    }
    void load()
    {
        if (!exists(storagePath)) return;
        try foreach (line; readText(storagePath).splitLines())
        {
            const separator=line.indexOf(':'); if(separator<=0) continue;
            const key=strip(line[0..separator]), value=strip(line[separator+1..$]);
            try switch(key)
            {
                case "fov":fov=to!float(value);break; case "mouseSensitivity":mouseSensitivity=to!float(value);break;
                case "masterVolume":masterVolume=to!float(value);break; case "soundVolume":soundVolume=to!float(value);break;
                case "fullscreen":fullscreen=to!bool(value);break; case "viewBobbing":viewBobbing=to!bool(value);break;
                case "clouds":clouds=to!bool(value);break; case "entityShadows":entityShadows=to!bool(value);break;
                case "invertMouse", "invertMouseY":invertMouse=to!bool(value);break; case "invertMouseX":invertMouseX=to!bool(value);break;
                case "allowCursorChanges":allowCursorChanges=to!bool(value);break;
                default:extra[key]=value;break;
            }
            catch(ConvException){}
        }
        catch(Exception){}
        if(auto p="renderClouds" in extra) try clouds=to!int(*p)!=0; catch(ConvException){}
    }
}

private WidgetSpec[] widgetsFor(const OptionsMenuState state)
{
    WidgetSpec[] r;
    void add(OptionsAction a,int row,int col=0,bool full=false,
        WidgetKind kind=WidgetKind.button,bool enabled=true)
    { r~=WidgetSpec(a,row,col,full,enabled,kind,""); }
    void heading(string s,int row,int col=0)
    { r~=WidgetSpec(OptionsAction.none,row,col,col==0,false,WidgetKind.heading,s); }
    void display(string s,int row,int col=0)
    { r~=WidgetSpec(OptionsAction.none,row,col,false,false,WidgetKind.display,s); }
    final switch(state.screen)
    {
        case OptionsScreen.main:
            add(OptionsAction.fov,0,0,false,WidgetKind.slider); add(OptionsAction.onlineMenu,0,1);
            add(OptionsAction.skinMenu,2,0); add(OptionsAction.soundsMenu,2,1);
            add(OptionsAction.videoMenu,3,0); add(OptionsAction.controlsMenu,3,1);
            add(OptionsAction.languageMenu,4,0); add(OptionsAction.chatMenu,4,1);
            add(OptionsAction.resourcePacksMenu,5,0); add(OptionsAction.accessibilityMenu,5,1);
            add(OptionsAction.telemetryMenu,6,0); add(OptionsAction.creditsMenu,6,1);
            add(OptionsAction.done,100,0,true); break;
        case OptionsScreen.online:
            heading("Friends List",0); add(OptionsAction.friendsList,1,0,false,WidgetKind.button,false); add(OptionsAction.allowFriendRequests,1,1,false,WidgetKind.button,false);
            add(OptionsAction.inGameNotification,2,0,false,WidgetKind.button,false); add(OptionsAction.sharePresence,2,1,false,WidgetKind.button,false);
            add(OptionsAction.xboxSettings,3,0,true,WidgetKind.button,false);
            heading("Servers",4); add(OptionsAction.allowServerListing,5,0,true,WidgetKind.button,false);
            heading("Realms",6); add(OptionsAction.realmsNotifications,7,0,true,WidgetKind.button,false);
            add(OptionsAction.done,100,0,true); break;
        case OptionsScreen.skin:
            add(OptionsAction.cape,0,0,false,WidgetKind.button,false); add(OptionsAction.jacket,0,1);
            add(OptionsAction.leftSleeve,1,0); add(OptionsAction.rightSleeve,1,1);
            add(OptionsAction.leftPantLeg,2,0); add(OptionsAction.rightPantLeg,2,1);
            add(OptionsAction.hat,3,0); add(OptionsAction.mainHand,3,1,false,WidgetKind.button,false);
            add(OptionsAction.done,100,0,true); break;
        case OptionsScreen.sounds:
            add(OptionsAction.masterVolume,0,0,true,WidgetKind.slider);
            add(OptionsAction.musicVolume,1,0,false,WidgetKind.slider,false); add(OptionsAction.recordVolume,1,1,false,WidgetKind.slider,false);
            add(OptionsAction.weatherVolume,2,0,false,WidgetKind.slider,false); add(OptionsAction.soundVolume,2,1,false,WidgetKind.slider);
            add(OptionsAction.hostileVolume,3,0,false,WidgetKind.slider,false); add(OptionsAction.neutralVolume,3,1,false,WidgetKind.slider,false);
            add(OptionsAction.playerVolume,4,0,false,WidgetKind.slider); add(OptionsAction.ambientVolume,4,1,false,WidgetKind.slider,false);
            add(OptionsAction.voiceVolume,5,0,false,WidgetKind.slider,false); add(OptionsAction.uiVolume,5,1,false,WidgetKind.slider);
            add(OptionsAction.audioDevice,6,0,true,WidgetKind.button,false);
            add(OptionsAction.subtitles,7,0,false,WidgetKind.button,false); add(OptionsAction.directionalAudio,7,1);
            add(OptionsAction.musicFrequency,8,0,false,WidgetKind.button,false); add(OptionsAction.musicToast,8,1,false,WidgetKind.button,false);
            add(OptionsAction.done,100,0,true); break;
        case OptionsScreen.video:
            heading("Display",0); add(OptionsAction.fullscreenResolution,1,0,true,WidgetKind.slider,false);
            add(OptionsAction.maxFramerate,2,0,false,WidgetKind.slider); add(OptionsAction.vsync,2,1);
            add(OptionsAction.inactivityFpsLimit,3,0,false,WidgetKind.button,false); add(OptionsAction.guiScale,3,1,false,WidgetKind.button,false);
            add(OptionsAction.fullscreen,4,0); add(OptionsAction.exclusiveFullscreen,4,1,false,WidgetKind.button,false);
            add(OptionsAction.brightness,5,0,false,WidgetKind.slider); add(OptionsAction.graphicsApi,5,1,false,WidgetKind.button,false);
            heading("Quality & Performance",6); add(OptionsAction.graphicsPreset,7,0); add(OptionsAction.biomeBlend,7,1,false,WidgetKind.slider,false);
            add(OptionsAction.renderDistance,8,0,false,WidgetKind.slider,false); add(OptionsAction.chunkBuilder,8,1,false,WidgetKind.button,false);
            add(OptionsAction.simulationDistance,9,0,false,WidgetKind.slider,false); add(OptionsAction.smoothLighting,9,1);
            add(OptionsAction.clouds,10,0); add(OptionsAction.particles,10,1);
            add(OptionsAction.mipmapLevels,11,0,false,WidgetKind.slider,false); add(OptionsAction.entityShadows,11,1);
            add(OptionsAction.entityDistance,12,0,false,WidgetKind.slider,false); add(OptionsAction.menuBackgroundBlur,12,1,false,WidgetKind.slider,false);
            add(OptionsAction.cloudDistance,13,0,false,WidgetKind.slider,false); add(OptionsAction.cutoutLeaves,13,1,false,WidgetKind.button,false);
            add(OptionsAction.improvedTransparency,14,0,false,WidgetKind.button,false); add(OptionsAction.textureFiltering,14,1,false,WidgetKind.button,false);
            add(OptionsAction.anisotropicFiltering,15,0,false,WidgetKind.slider,false); add(OptionsAction.weatherRadius,15,1,false,WidgetKind.slider,false);
            heading("Preferences",16); add(OptionsAction.autosaveIndicator,17,0,false,WidgetKind.button,false); add(OptionsAction.vignette,17,1,false,WidgetKind.button,false);
            add(OptionsAction.attackIndicator,18,0,false,WidgetKind.button,false); add(OptionsAction.chunkFade,18,1,false,WidgetKind.slider,false);
            add(OptionsAction.done,100,0,true); break;
        case OptionsScreen.controls:
            add(OptionsAction.mouseMenu,0,0); add(OptionsAction.keyBindsMenu,0,1);
            add(OptionsAction.sneakMode,1,0); add(OptionsAction.sprintMode,1,1);
            add(OptionsAction.attackMode,2,0); add(OptionsAction.useMode,2,1);
            add(OptionsAction.autoJump,3,0); add(OptionsAction.sprintWindow,3,1,false,WidgetKind.slider,false);
            add(OptionsAction.operatorItemsTab,4,0,false,WidgetKind.button,false); add(OptionsAction.done,100,0,true); break;
        case OptionsScreen.mouse:
            add(OptionsAction.sensitivity,0,0,false,WidgetKind.slider); add(OptionsAction.scrollSensitivity,0,1,false,WidgetKind.slider,false);
            add(OptionsAction.discreteScrolling,1,0,false,WidgetKind.button,false); add(OptionsAction.rawInput,1,1,false,WidgetKind.button,false);
            add(OptionsAction.invertMouseX,2,0); add(OptionsAction.invertMouseY,2,1);
            add(OptionsAction.allowCursorChanges,3,0,true); add(OptionsAction.done,100,0,true); break;
        case OptionsScreen.keyBinds:
            add(OptionsAction.keyboardMouseMenu,1,0,true);
            add(OptionsAction.controllerMenu,2,0,true);
            add(OptionsAction.done,100,0,true); break;
        case OptionsScreen.keyboardMouse:
            heading("Movement",0); add(OptionsAction.bindForward,1,0); add(OptionsAction.bindLeft,1,1);
            add(OptionsAction.bindBack,2,0); add(OptionsAction.bindRight,2,1);
            add(OptionsAction.bindJump,3,0); add(OptionsAction.bindSneak,3,1);
            add(OptionsAction.bindSprint,4,0); heading("Gameplay",5);
            add(OptionsAction.bindAttack,6,0); add(OptionsAction.bindUse,6,1);
            add(OptionsAction.bindPickBlock,7,0); add(OptionsAction.bindDrop,7,1);
            add(OptionsAction.bindInventory,8,0);
            heading("Multiplayer",9); add(OptionsAction.bindChat,10,0); add(OptionsAction.bindFriends,10,1,false,WidgetKind.button,false);
            heading("Miscellaneous",11); add(OptionsAction.bindPerspective,12,0);
            add(OptionsAction.bindHotbar1,13,0); add(OptionsAction.bindHotbar2,13,1);
            add(OptionsAction.bindHotbar3,14,0); add(OptionsAction.bindHotbar4,14,1);
            add(OptionsAction.bindHotbar5,15,0); add(OptionsAction.bindHotbar6,15,1);
            add(OptionsAction.bindHotbar7,16,0); add(OptionsAction.bindHotbar8,16,1);
            add(OptionsAction.bindHotbar9,17,0); add(OptionsAction.resetKeys,18,0,true);
            add(OptionsAction.done,100,0,true); break;
        case OptionsScreen.controller:
            heading("Controller support is coming next.",1);
            display("Controller input is not available yet.",2,0);
            add(OptionsAction.done,100,0,true); break;
        case OptionsScreen.language:
            heading("Search",0); display("English (US)",1,0);
            add(OptionsAction.selectedLanguage,2,0,true,WidgetKind.button,false);
            add(OptionsAction.fontMenu,3,0); add(OptionsAction.done,3,1); break;
        case OptionsScreen.font:
            add(OptionsAction.forceUnicodeFont,0,0,false,WidgetKind.button,false); add(OptionsAction.japaneseGlyphVariants,0,1,false,WidgetKind.button,false);
            add(OptionsAction.done,100,0,true); break;
        case OptionsScreen.chat:
            add(OptionsAction.chatVisibility,0,0); add(OptionsAction.chatColors,0,1);
            add(OptionsAction.webLinks,1,0,false,WidgetKind.button,false); add(OptionsAction.promptLinks,1,1,false,WidgetKind.button,false);
            add(OptionsAction.chatOpacity,2,0,false,WidgetKind.slider); add(OptionsAction.textBackgroundOpacity,2,1,false,WidgetKind.slider);
            add(OptionsAction.chatScale,3,0,false,WidgetKind.slider,false); add(OptionsAction.lineSpacing,3,1,false,WidgetKind.slider);
            add(OptionsAction.chatDelay,4,0,false,WidgetKind.slider,false); add(OptionsAction.chatWidth,4,1,false,WidgetKind.slider);
            add(OptionsAction.focusedHeight,5,0,false,WidgetKind.slider); add(OptionsAction.unfocusedHeight,5,1,false,WidgetKind.slider);
            add(OptionsAction.narrator,6,0,false,WidgetKind.button,false); add(OptionsAction.commandSuggestions,6,1,false,WidgetKind.button,false);
            add(OptionsAction.hideMatchedNames,7,0,false,WidgetKind.button,false); add(OptionsAction.reducedDebugInfo,7,1,false,WidgetKind.button,false);
            add(OptionsAction.secureChat,8,0,false,WidgetKind.button,false); add(OptionsAction.saveUnsentChats,8,1);
            add(OptionsAction.done,100,0,true); break;
        case OptionsScreen.resourcePacks:
            heading("Available",0,0); heading("Selected",0,1);
            display("High Contrast (built-in)",1,0); display("Default (built-in)",1,1);
            display("Programmer Art (built-in)",2,0);
            add(OptionsAction.openPackFolder,100,0,false,WidgetKind.button,false); add(OptionsAction.done,100,1); break;
        case OptionsScreen.accessibility:
            add(OptionsAction.narrator,0,0,false,WidgetKind.button,false); add(OptionsAction.controlsMenu,0,1);
            add(OptionsAction.subtitles,1,0,false,WidgetKind.button,false); add(OptionsAction.highContrast,1,1,false,WidgetKind.button,false);
            add(OptionsAction.menuBackgroundBlur,2,0,false,WidgetKind.slider,false); add(OptionsAction.textBackgroundOpacity,2,1,false,WidgetKind.slider);
            add(OptionsAction.textBackgroundMode,3,0,false,WidgetKind.button,false); add(OptionsAction.chatOpacity,3,1,false,WidgetKind.slider);
            add(OptionsAction.lineSpacing,4,0,false,WidgetKind.slider); add(OptionsAction.chatDelay,4,1,false,WidgetKind.slider,false);
            add(OptionsAction.notificationTime,5,0,false,WidgetKind.slider,false); add(OptionsAction.viewBobbing,5,1);
            add(OptionsAction.distortionEffects,6,0,false,WidgetKind.slider,false); add(OptionsAction.fovEffects,6,1,false,WidgetKind.slider,false);
            add(OptionsAction.darknessPulsing,7,0,false,WidgetKind.slider,false); add(OptionsAction.damageTilt,7,1,false,WidgetKind.slider,false);
            add(OptionsAction.glintSpeed,8,0,false,WidgetKind.slider,false); add(OptionsAction.glintStrength,8,1,false,WidgetKind.slider,false);
            add(OptionsAction.hideSkyFlashes,9,0,false,WidgetKind.button,false); add(OptionsAction.monochromeLogo,9,1,false,WidgetKind.button,false);
            add(OptionsAction.panoramaSpeed,10,0,false,WidgetKind.slider,false); add(OptionsAction.hideSplashTexts,10,1,false,WidgetKind.button,false);
            add(OptionsAction.narratorHotkey,11,0,false,WidgetKind.button,false); add(OptionsAction.rotateWithMinecarts,11,1,false,WidgetKind.button,false);
            add(OptionsAction.highContrastBlockOutlines,12,0,true,WidgetKind.button,false);
            add(OptionsAction.done,100,0,true); break;
        case OptionsScreen.telemetry:
            heading("Telemetry Data",0); add(OptionsAction.telemetryCollection,1,0,true,WidgetKind.button,false);
            display("D Edition sends no Mojang telemetry.",2,0); add(OptionsAction.done,100,0,true); break;
        case OptionsScreen.credits:
            add(OptionsAction.showCredits,0,0,true,WidgetKind.button,false);
            add(OptionsAction.showAttribution,1,0,true,WidgetKind.button,false);
            add(OptionsAction.showLicensing,2,0,true,WidgetKind.button,false);
            add(OptionsAction.done,100,0,true); break;
    }
    return r;
}

private OptionRect widgetRect(WidgetSpec spec,int width,int height,const OptionsMenuState state)
{
    const center=width/2,left=center-154,right=center+2;
    if(spec.row==100)
    {
        if(state.screen==OptionsScreen.resourcePacks&&!spec.fullWidth)
            return OptionRect(spec.column==0?left:right,height-28,152,20);
        return OptionRect(center-100,height-28,200,20);
    }
    if(state.screen==OptionsScreen.main)
    {
        const y=spec.row==0?29:40+spec.row*24;
        return OptionRect(spec.fullWidth?center-154:(spec.column==0?left:right),y,spec.fullWidth?308:152,20);
    }
    const y=38+(spec.row-state.scrollRow)*24;
    return OptionRect(spec.fullWidth?center-154:(spec.column==0?left:right),y,spec.fullWidth?308:152,20);
}

private int maximumScrollRow(uint viewportWidth,uint viewportHeight,
    const OptionsMenuState state,bool alreadyLogical=false)
{
    int width=cast(int)viewportWidth,height=cast(int)viewportHeight;
    if(!alreadyLogical){const scale=guiScale(viewportWidth,viewportHeight);width/=scale;height/=scale;}
    int maxRow; foreach(spec;widgetsFor(state))if(spec.row!=100&&spec.row>maxRow)maxRow=spec.row;
    const visible=(height-contentTop(state.screen)-34)/24;
    return clampInt(maxRow-visible+1,0,maxRow);
}

private int contentTop(OptionsScreen screen){return screen==OptionsScreen.main?29:38;}

private OptionsScreen destinationScreen(OptionsAction a)
{
    switch(a)
    {
        case OptionsAction.onlineMenu:return OptionsScreen.online; case OptionsAction.skinMenu:return OptionsScreen.skin;
        case OptionsAction.soundsMenu:return OptionsScreen.sounds; case OptionsAction.videoMenu:return OptionsScreen.video;
        case OptionsAction.controlsMenu:return OptionsScreen.controls; case OptionsAction.mouseMenu:return OptionsScreen.mouse;
        case OptionsAction.keyBindsMenu:return OptionsScreen.keyBinds; case OptionsAction.languageMenu:return OptionsScreen.language;
        case OptionsAction.keyboardMouseMenu:return OptionsScreen.keyboardMouse; case OptionsAction.controllerMenu:return OptionsScreen.controller;
        case OptionsAction.fontMenu:return OptionsScreen.font; case OptionsAction.chatMenu:return OptionsScreen.chat;
        case OptionsAction.resourcePacksMenu:return OptionsScreen.resourcePacks; case OptionsAction.accessibilityMenu:return OptionsScreen.accessibility;
        case OptionsAction.telemetryMenu:return OptionsScreen.telemetry; case OptionsAction.creditsMenu:return OptionsScreen.credits;
        default:return OptionsScreen.main;
    }
}

private string screenTitle(OptionsScreen s)
{
    final switch(s)
    {
        case OptionsScreen.main:return "Options"; case OptionsScreen.online:return "Online Options";
        case OptionsScreen.skin:return "Skin Customization"; case OptionsScreen.sounds:return "Music & Sound Options";
        case OptionsScreen.video:return "Video Settings"; case OptionsScreen.controls:return "Controls";
        case OptionsScreen.mouse:return "Mouse Settings"; case OptionsScreen.keyBinds:return "Key Binds";
        case OptionsScreen.keyboardMouse:return "Keyboard & Mouse"; case OptionsScreen.controller:return "Controller";
        case OptionsScreen.language:return "Language"; case OptionsScreen.font:return "Font Settings";
        case OptionsScreen.chat:return "Chat Settings"; case OptionsScreen.resourcePacks:return "Select Resource Packs";
        case OptionsScreen.accessibility:return "Accessibility Settings"; case OptionsScreen.telemetry:return "Telemetry Data";
        case OptionsScreen.credits:return "Credits & Attribution";
    }
}

private string label(OptionsAction a,const OptionsMenuState s)
{
    string toggle(string n,bool v){return n~": "~(v?"ON":"OFF");}
    string volume(string n,float v){return v<=.001f?n~": OFF":format("%s: %s%%",n,cast(int)(v*100));}
    string percent(string n,float v){return format("%s: %s%%",n,cast(int)(v*100));}
    string choice(string n,string[] values,int selected)
    {return n~": "~values[clampInt(selected,0,cast(int)values.length-1)];}
    switch(a)
    {
        case OptionsAction.done:return "Done";
        case OptionsAction.fov:return cast(int)s.fov==70?"FOV: Normal":(cast(int)s.fov==110?"FOV: Quake Pro":"FOV: "~to!string(cast(int)s.fov));
        case OptionsAction.onlineMenu:return "Online..."; case OptionsAction.skinMenu:return "Skin Customization...";
        case OptionsAction.soundsMenu:return "Music & Sounds..."; case OptionsAction.videoMenu:return "Video Settings...";
        case OptionsAction.controlsMenu:return "Controls..."; case OptionsAction.languageMenu:return "Language...";
        case OptionsAction.chatMenu:return "Chat Settings..."; case OptionsAction.resourcePacksMenu:return "Resource Packs...";
        case OptionsAction.accessibilityMenu:return "Accessibility Settings..."; case OptionsAction.telemetryMenu:return "Telemetry Data...";
        case OptionsAction.creditsMenu:return "Credits & Attribution..."; case OptionsAction.mouseMenu:return "Mouse Settings...";
        case OptionsAction.keyBindsMenu:return "Key Binds..."; case OptionsAction.fontMenu:return "Font Settings...";
        case OptionsAction.keyboardMouseMenu:return "Keyboard & Mouse"; case OptionsAction.controllerMenu:return "Controller";
        case OptionsAction.masterVolume:return volume("Master Volume",s.masterVolume);
        case OptionsAction.soundVolume:return volume("Blocks",s.soundVolume);
        case OptionsAction.fullscreen:return toggle("Fullscreen",s.fullscreen);
        case OptionsAction.viewBobbing:return toggle("View Bobbing",s.viewBobbing);
        case OptionsAction.entityShadows:return toggle("Entity Shadows",s.entityShadows);
        case OptionsAction.invertMouseX:return toggle("Invert Mouse X",s.invertMouseX);
        case OptionsAction.invertMouseY:return toggle("Invert Mouse Y",s.invertMouse);
        case OptionsAction.allowCursorChanges:return toggle("Allow Cursor Changes",s.allowCursorChanges);
        case OptionsAction.musicVolume:return volume("Music",s.number("soundCategory_music",1));
        case OptionsAction.recordVolume:return volume("Jukebox/Note Blocks",s.number("soundCategory_record",1));
        case OptionsAction.weatherVolume:return volume("Weather",s.number("soundCategory_weather",1));
        case OptionsAction.hostileVolume:return volume("Hostile Mobs",s.number("soundCategory_hostile",1));
        case OptionsAction.neutralVolume:return volume("Friendly Mobs",s.number("soundCategory_neutral",1));
        case OptionsAction.playerVolume:return volume("Players",s.number("soundCategory_player",1));
        case OptionsAction.ambientVolume:return volume("Ambient/Environment",s.number("soundCategory_ambient",1));
        case OptionsAction.voiceVolume:return volume("Narrator/Voice",s.number("soundCategory_voice",1));
        case OptionsAction.uiVolume:return volume("UI",s.number("soundCategory_ui",1));
        case OptionsAction.audioDevice:return "Device: System Default";
        case OptionsAction.fullscreenResolution:return "Fullscreen Resolution: Current";
        case OptionsAction.exclusiveFullscreen:return "Exclusive Fullscreen: OFF";
        case OptionsAction.graphicsApi:return "Graphics API: DirectX 12";
        case OptionsAction.maxFramerate:return "Max Framerate: "~to!string(s.integer("maxFps",120))~" fps";
        case OptionsAction.brightness:return percent("Brightness",s.number("gamma",.5f));
        case OptionsAction.biomeBlend:
            const blend=s.integer("biomeBlendRadius",5); return format("Biome Blend: %sx%s",blend,blend);
        case OptionsAction.renderDistance:return "Render Distance: "~to!string(s.integer("renderDistance",16))~" Chunks";
        case OptionsAction.simulationDistance:return "Simulation Distance: "~to!string(s.integer("simulationDistance",12))~" Chunks";
        case OptionsAction.mipmapLevels:return "Mipmap Levels: "~to!string(s.integer("mipmapLevels",4));
        case OptionsAction.entityDistance:return percent("Entity Distance",s.number("entityDistanceScaling",1));
        case OptionsAction.menuBackgroundBlur:return "Menu Background Blur: "~to!string(s.integer("menuBackgroundBlurriness",5));
        case OptionsAction.cloudDistance:return "Cloud Distance: "~to!string(s.integer("renderCloudsDistance",64))~" Chunks";
        case OptionsAction.anisotropicFiltering:return "Anisotropic Filtering: "~to!string(s.integer("maxAnisotropy",4))~"x";
        case OptionsAction.weatherRadius:return "Weather Effect Radius: "~to!string(s.integer("weatherRadius",10))~" Blocks";
        case OptionsAction.chunkFade:return s.number("chunkFade",.75f)<=.01f?"Chunk Fade: None":format("Chunk Fade: %.2f seconds",s.number("chunkFade",.75f));
        case OptionsAction.sensitivity:return percent("Sensitivity",s.mouseSensitivity);
        case OptionsAction.scrollSensitivity:return format("Scroll Sensitivity: %.2f",s.number("mouseWheelSensitivity",1));
        case OptionsAction.sprintWindow:return "Sprint Window: "~to!string(s.integer("sprintWindow",7));
        case OptionsAction.chatOpacity:return percent("Chat Text Opacity",s.number("chatOpacity",1));
        case OptionsAction.textBackgroundOpacity:return percent("Text Background Opacity",s.number("textBackgroundOpacity",.5f));
        case OptionsAction.chatScale:return percent("Chat Text Size",s.number("chatScale",1));
        case OptionsAction.lineSpacing:return percent("Line Spacing",s.number("chatLineSpacing",0));
        case OptionsAction.chatDelay:return s.number("chatDelay",0)<=.01f?"Chat Delay: None":format("Chat Delay: %.1f seconds",s.number("chatDelay",0));
        case OptionsAction.chatWidth:return "Width: "~to!string(cast(int)(40+s.number("chatWidth",1)*280))~"px";
        case OptionsAction.focusedHeight:return "Focused Height: "~to!string(cast(int)(20+s.number("chatHeightFocused",1)*160))~"px";
        case OptionsAction.unfocusedHeight:return "Unfocused Height: "~to!string(cast(int)(20+s.number("chatHeightUnfocused",.44f)*160))~"px";
        case OptionsAction.notificationTime:return format("Notification Time: %.1fx",s.number("notificationTime",1));
        case OptionsAction.distortionEffects:return percent("Distortion Effects",s.number("screenEffectScale",1));
        case OptionsAction.fovEffects:return percent("FOV Effects",s.number("fovEffectScale",1));
        case OptionsAction.darknessPulsing:return percent("Darkness Pulsing",s.number("darknessEffectScale",1));
        case OptionsAction.damageTilt:return percent("Damage Tilt",s.number("damageTiltStrength",1));
        case OptionsAction.glintSpeed:return percent("Glint Speed",s.number("glintSpeed",.5f));
        case OptionsAction.glintStrength:return percent("Glint Strength",s.number("glintStrength",.75f));
        case OptionsAction.panoramaSpeed:return percent("Panorama Scroll Speed",s.number("panoramaSpeed",1));
        case OptionsAction.sharePresence:return choice("Visibility",["Hidden","Limited","Full"],s.integer("sharePresence",2));
        case OptionsAction.mainHand:return choice("Main Hand",["Left","Right"],s.integer("mainHand",1));
        case OptionsAction.musicFrequency:return choice("Music Frequency",["Default","Frequent","Constant"],s.integer("musicFrequency",0));
        case OptionsAction.musicToast:return choice("Music Toast",["Never","Pause Menu","Pause Menu and Toast"],s.integer("musicToast",0));
        case OptionsAction.inactivityFpsLimit:return choice("Reduce FPS when",["AFK","Minimized"],s.integer("inactivityFpsLimit",0));
        case OptionsAction.guiScale:return choice("GUI Scale",["Auto","1","2","3","4"],s.integer("guiScale",0));
        case OptionsAction.graphicsPreset:return choice("Preset",["Fast","Fancy","Fabulous!","Custom"],s.integer("graphicsPreset",1));
        case OptionsAction.chunkBuilder:return choice("Chunk Builder",["Threaded","Semi Blocking","Fully Blocking"],s.integer("prioritizeChunkUpdates",1));
        case OptionsAction.smoothLighting:return choice("Smooth Lighting",["OFF","Minimum","Maximum"],s.integer("ao",2));
        case OptionsAction.clouds:return choice("Clouds",["OFF","Fast","Fancy"],s.integer("renderClouds",s.clouds?2:0));
        case OptionsAction.particles:return choice("Particles",["All","Decreased","Minimal"],s.integer("particles",0));
        case OptionsAction.textureFiltering:return choice("Texture Filtering",["None","RGSS","Anisotropic"],s.integer("textureFiltering",1));
        case OptionsAction.attackIndicator:return choice("Attack Indicator",["OFF","Crosshair","Hotbar"],s.integer("attackIndicator",1));
        case OptionsAction.sneakMode:return choice("Sneak",["Hold","Toggle"],s.integer("sneakMode",0));
        case OptionsAction.sprintMode:return choice("Sprint",["Hold","Toggle"],s.integer("sprintMode",0));
        case OptionsAction.attackMode:return choice("Attack/Destroy",["Hold","Toggle"],s.integer("attackMode",0));
        case OptionsAction.useMode:return choice("Use Item/Place Block",["Hold","Toggle"],s.integer("useMode",0));
        case OptionsAction.chatVisibility:return choice("Chat",["Shown","Commands Only","Hidden"],s.integer("chatVisibility",0));
        case OptionsAction.narrator:return choice("Narrator",["OFF","Narrates All","Narrates Chat","Narrates System"],s.integer("narrator",0));
        case OptionsAction.textBackgroundMode:return choice("Text Background",["Chat","Everywhere"],s.integer("textBackgroundMode",0));
        case OptionsAction.telemetryCollection:return "Data Collection: None";
        case OptionsAction.selectedLanguage:return "English (US)"; case OptionsAction.openPackFolder:return "Open Pack Folder";
        case OptionsAction.resetKeys:return "Reset Keys"; case OptionsAction.xboxSettings:return "Xbox Settings...";
        case OptionsAction.showCredits:return "Credits"; case OptionsAction.showAttribution:return "Attribution";
        case OptionsAction.showLicensing:return "Licensing";
        default:
            if (s.isBindingAction(a)) return bindingLabel(a,s);
            const key=booleanKey(a); return key.length?toggle(booleanName(a),s.boolean(key,defaultBoolean(a))):"";
    }
}

private float sliderAmount(OptionsAction a,const OptionsMenuState s)
{
    switch(a)
    {
        case OptionsAction.fov:return(s.fov-30)/80; case OptionsAction.sensitivity:return(s.mouseSensitivity-.25f)/1.75f;
        case OptionsAction.masterVolume:return s.masterVolume; case OptionsAction.soundVolume:return s.soundVolume;
        case OptionsAction.musicVolume:return s.number("soundCategory_music",1); case OptionsAction.recordVolume:return s.number("soundCategory_record",1);
        case OptionsAction.weatherVolume:return s.number("soundCategory_weather",1); case OptionsAction.hostileVolume:return s.number("soundCategory_hostile",1);
        case OptionsAction.neutralVolume:return s.number("soundCategory_neutral",1); case OptionsAction.playerVolume:return s.number("soundCategory_player",1);
        case OptionsAction.ambientVolume:return s.number("soundCategory_ambient",1); case OptionsAction.voiceVolume:return s.number("soundCategory_voice",1);
        case OptionsAction.uiVolume:return s.number("soundCategory_ui",1); case OptionsAction.maxFramerate:return(s.integer("maxFps",120)-10)/250f;
        case OptionsAction.brightness:return s.number("gamma",.5f); case OptionsAction.biomeBlend:return(s.integer("biomeBlendRadius",5)-1)/14f;
        case OptionsAction.renderDistance:return(s.integer("renderDistance",16)-2)/30f; case OptionsAction.simulationDistance:return(s.integer("simulationDistance",12)-5)/27f;
        case OptionsAction.mipmapLevels:return s.integer("mipmapLevels",4)/4f; case OptionsAction.entityDistance:return(s.number("entityDistanceScaling",1)-.5f)/4.5f;
        case OptionsAction.menuBackgroundBlur:return s.integer("menuBackgroundBlurriness",5)/10f; case OptionsAction.cloudDistance:return(s.integer("renderCloudsDistance",64)-32)/96f;
        case OptionsAction.anisotropicFiltering:return(s.integer("maxAnisotropy",4)-1)/15f; case OptionsAction.weatherRadius:return(s.integer("weatherRadius",10)-1)/31f;
        case OptionsAction.chunkFade:return s.number("chunkFade",.75f)/5; case OptionsAction.sprintWindow:return(s.integer("sprintWindow",7)-1)/19f;
        case OptionsAction.scrollSensitivity:return(s.number("mouseWheelSensitivity",1)-.01f)/9.99f;
        case OptionsAction.chatOpacity:return s.number("chatOpacity",1); case OptionsAction.textBackgroundOpacity:return s.number("textBackgroundOpacity",.5f);
        case OptionsAction.chatScale:return s.number("chatScale",1); case OptionsAction.lineSpacing:return s.number("chatLineSpacing",0);
        case OptionsAction.chatDelay:return s.number("chatDelay",0)/6; case OptionsAction.chatWidth:return s.number("chatWidth",1);
        case OptionsAction.focusedHeight:return s.number("chatHeightFocused",1); case OptionsAction.unfocusedHeight:return s.number("chatHeightUnfocused",.44f);
        case OptionsAction.notificationTime:return(s.number("notificationTime",1)-.5f)/4.5f;
        case OptionsAction.distortionEffects:return s.number("screenEffectScale",1); case OptionsAction.fovEffects:return s.number("fovEffectScale",1);
        case OptionsAction.darknessPulsing:return s.number("darknessEffectScale",1); case OptionsAction.damageTilt:return s.number("damageTiltStrength",1);
        case OptionsAction.glintSpeed:return s.number("glintSpeed",.5f); case OptionsAction.glintStrength:return s.number("glintStrength",.75f);
        case OptionsAction.panoramaSpeed:return s.number("panoramaSpeed",1); default:return 0;
    }
}

private string bindingKey(OptionsAction a)
{
    switch(a)
    {
        case OptionsAction.bindForward:return"key_forward"; case OptionsAction.bindBack:return"key_back";
        case OptionsAction.bindLeft:return"key_left"; case OptionsAction.bindRight:return"key_right";
        case OptionsAction.bindJump:return"key_jump"; case OptionsAction.bindSneak:return"key_sneak";
        case OptionsAction.bindSprint:return"key_sprint"; case OptionsAction.bindAttack:return"key_attack";
        case OptionsAction.bindUse:return"key_use"; case OptionsAction.bindPickBlock:return"key_pick_item";
        case OptionsAction.bindDrop:return"key_drop";
        case OptionsAction.bindInventory:return"key_inventory"; case OptionsAction.bindChat:return"key_chat";
        case OptionsAction.bindFriends:return"key_friends"; case OptionsAction.bindPerspective:return"key_perspective";
        case OptionsAction.bindHotbar1:return"key_hotbar_1"; case OptionsAction.bindHotbar2:return"key_hotbar_2";
        case OptionsAction.bindHotbar3:return"key_hotbar_3"; case OptionsAction.bindHotbar4:return"key_hotbar_4";
        case OptionsAction.bindHotbar5:return"key_hotbar_5"; case OptionsAction.bindHotbar6:return"key_hotbar_6";
        case OptionsAction.bindHotbar7:return"key_hotbar_7"; case OptionsAction.bindHotbar8:return"key_hotbar_8";
        case OptionsAction.bindHotbar9:return"key_hotbar_9"; default:return"";
    }
}

private int defaultBinding(OptionsAction a)
{
    switch(a)
    {
        case OptionsAction.bindForward:return'W'; case OptionsAction.bindBack:return'S';
        case OptionsAction.bindLeft:return'A'; case OptionsAction.bindRight:return'D';
        case OptionsAction.bindJump:return 0x20; case OptionsAction.bindSneak:return 0x10;
        case OptionsAction.bindSprint:return 0x11; case OptionsAction.bindAttack:return 0x01;
        case OptionsAction.bindUse:return 0x02; case OptionsAction.bindPickBlock:return 0x04;
        case OptionsAction.bindDrop:return'Q';
        case OptionsAction.bindInventory:return'E'; case OptionsAction.bindChat:return'T';
        case OptionsAction.bindFriends:return'O'; case OptionsAction.bindPerspective:return 0x74;
        case OptionsAction.bindHotbar1:return'1'; case OptionsAction.bindHotbar2:return'2';
        case OptionsAction.bindHotbar3:return'3'; case OptionsAction.bindHotbar4:return'4';
        case OptionsAction.bindHotbar5:return'5'; case OptionsAction.bindHotbar6:return'6';
        case OptionsAction.bindHotbar7:return'7'; case OptionsAction.bindHotbar8:return'8';
        case OptionsAction.bindHotbar9:return'9'; default:return 0;
    }
}

private string bindingName(OptionsAction a)
{
    switch(a)
    {
        case OptionsAction.bindForward:return"Forward"; case OptionsAction.bindBack:return"Back";
        case OptionsAction.bindLeft:return"Left"; case OptionsAction.bindRight:return"Right";
        case OptionsAction.bindJump:return"Jump"; case OptionsAction.bindSneak:return"Sneak";
        case OptionsAction.bindSprint:return"Sprint"; case OptionsAction.bindAttack:return"Attack/Destroy";
        case OptionsAction.bindUse:return"Use Item/Place Block"; case OptionsAction.bindPickBlock:return"Pick Block";
        case OptionsAction.bindDrop:return"Drop Selected Item";
        case OptionsAction.bindInventory:return"Open/Close Inventory"; case OptionsAction.bindChat:return"Open Chat";
        case OptionsAction.bindFriends:return"Friends List"; case OptionsAction.bindPerspective:return"Toggle Perspective";
        case OptionsAction.bindHotbar1:return"Hotbar Slot 1"; case OptionsAction.bindHotbar2:return"Hotbar Slot 2";
        case OptionsAction.bindHotbar3:return"Hotbar Slot 3"; case OptionsAction.bindHotbar4:return"Hotbar Slot 4";
        case OptionsAction.bindHotbar5:return"Hotbar Slot 5"; case OptionsAction.bindHotbar6:return"Hotbar Slot 6";
        case OptionsAction.bindHotbar7:return"Hotbar Slot 7"; case OptionsAction.bindHotbar8:return"Hotbar Slot 8";
        case OptionsAction.bindHotbar9:return"Hotbar Slot 9"; default:return"";
    }
}

private string virtualKeyName(int key)
{
    if(key>='A'&&key<='Z'||key>='0'&&key<='9')return [cast(char)key];
    switch(key)
    {
        case 0x01:return"Button 1"; case 0x02:return"Button 2"; case 0x04:return"Button 3";
        case 0x08:return"Backspace"; case 0x09:return"Tab"; case 0x0D:return"Enter";
        case 0x10:return"Left Shift"; case 0x11:return"Left Control"; case 0x12:return"Alt";
        case 0x1B:return"Escape"; case 0x20:return"Space"; case 0x25:return"Left Arrow";
        case 0x26:return"Up Arrow"; case 0x27:return"Right Arrow"; case 0x28:return"Down Arrow";
        case 0x70:return"F1"; case 0x71:return"F2"; case 0x72:return"F3"; case 0x73:return"F4";
        case 0x74:return"F5"; case 0x75:return"F6"; case 0x76:return"F7"; case 0x77:return"F8";
        case 0x78:return"F9"; case 0x79:return"F10"; case 0x7A:return"F11"; case 0x7B:return"F12";
        default:return"Key "~to!string(key);
    }
}

private string bindingLabel(OptionsAction a,const OptionsMenuState s)
{
    const value=bindingName(a)~": "~virtualKeyName(s.key(a));
    return s.bindingCapture==a?"> "~value~" <":value;
}

private string booleanKey(OptionsAction a)
{
    switch(a)
    {
        case OptionsAction.friendsList:return"friendsList"; case OptionsAction.allowFriendRequests:return"allowFriendRequests";
        case OptionsAction.inGameNotification:return"inGameNotification"; case OptionsAction.allowServerListing:return"allowServerListing";
        case OptionsAction.realmsNotifications:return"realmsNotifications"; case OptionsAction.cape:return"modelPart_cape";
        case OptionsAction.jacket:return"modelPart_jacket"; case OptionsAction.leftSleeve:return"modelPart_leftSleeve";
        case OptionsAction.rightSleeve:return"modelPart_rightSleeve"; case OptionsAction.leftPantLeg:return"modelPart_leftPantLeg";
        case OptionsAction.rightPantLeg:return"modelPart_rightPantLeg"; case OptionsAction.hat:return"modelPart_hat";
        case OptionsAction.subtitles:return"showSubtitles"; case OptionsAction.directionalAudio:return"directionalAudio";
        case OptionsAction.vsync:return"vsync"; case OptionsAction.cutoutLeaves:return"cutoutLeaves";
        case OptionsAction.improvedTransparency:return"improvedTransparency"; case OptionsAction.autosaveIndicator:return"autosaveIndicator";
        case OptionsAction.vignette:return"vignette"; case OptionsAction.autoJump:return"autoJump";
        case OptionsAction.operatorItemsTab:return"operatorItemsTab"; case OptionsAction.discreteScrolling:return"discreteScrolling";
        case OptionsAction.rawInput:return"rawMouseInput"; case OptionsAction.forceUnicodeFont:return"forceUnicodeFont";
        case OptionsAction.japaneseGlyphVariants:return"japaneseGlyphVariants"; case OptionsAction.chatColors:return"chatColors";
        case OptionsAction.webLinks:return"webLinks"; case OptionsAction.promptLinks:return"promptLinks";
        case OptionsAction.commandSuggestions:return"autoSuggestCommands"; case OptionsAction.hideMatchedNames:return"hideMatchedNames";
        case OptionsAction.reducedDebugInfo:return"reducedDebugInfo"; case OptionsAction.secureChat:return"onlyShowSecureChat";
        case OptionsAction.saveUnsentChats:return"chatDrafts"; case OptionsAction.highContrast:return"highContrast";
        case OptionsAction.hideSkyFlashes:return"hideLightningFlashes"; case OptionsAction.monochromeLogo:return"monochromeLogo";
        case OptionsAction.hideSplashTexts:return"hideSplashTexts"; case OptionsAction.narratorHotkey:return"narratorHotkey";
        case OptionsAction.rotateWithMinecarts:return"rotateWithMinecarts"; case OptionsAction.highContrastBlockOutlines:return"highContrastBlockOutlines";
        default:return"";
    }
}

private string booleanName(OptionsAction a)
{
    switch(a)
    {
        case OptionsAction.friendsList:return"Friends List"; case OptionsAction.allowFriendRequests:return"Allow Requests";
        case OptionsAction.inGameNotification:return"In-Game Notification"; case OptionsAction.allowServerListing:return"Allow Server Listings";
        case OptionsAction.realmsNotifications:return"Realms News & Invites"; case OptionsAction.cape:return"Cape";
        case OptionsAction.jacket:return"Jacket"; case OptionsAction.leftSleeve:return"Left Sleeve";
        case OptionsAction.rightSleeve:return"Right Sleeve"; case OptionsAction.leftPantLeg:return"Left Pant Leg";
        case OptionsAction.rightPantLeg:return"Right Pant Leg"; case OptionsAction.hat:return"Hat";
        case OptionsAction.subtitles:return"Closed Captions"; case OptionsAction.directionalAudio:return"Directional Audio";
        case OptionsAction.vsync:return"VSync"; case OptionsAction.cutoutLeaves:return"See-Through Leaves";
        case OptionsAction.improvedTransparency:return"Improved Transparency"; case OptionsAction.autosaveIndicator:return"Autosave Indicator";
        case OptionsAction.vignette:return"Show Vignette"; case OptionsAction.autoJump:return"Auto-Jump";
        case OptionsAction.operatorItemsTab:return"Operator Items Tab"; case OptionsAction.discreteScrolling:return"Discrete Scrolling";
        case OptionsAction.rawInput:return"Raw Input"; case OptionsAction.forceUnicodeFont:return"Force Unicode Font";
        case OptionsAction.japaneseGlyphVariants:return"Japanese Glyph Variants"; case OptionsAction.chatColors:return"Colors";
        case OptionsAction.webLinks:return"Web Links"; case OptionsAction.promptLinks:return"Prompt on Links";
        case OptionsAction.commandSuggestions:return"Command Suggestions"; case OptionsAction.hideMatchedNames:return"Hide Matched Names";
        case OptionsAction.reducedDebugInfo:return"Reduced Debug Info"; case OptionsAction.secureChat:return"Only Show Secure Chat";
        case OptionsAction.saveUnsentChats:return"Save Unsent Chats"; case OptionsAction.highContrast:return"High Contrast";
        case OptionsAction.hideSkyFlashes:return"Hide Sky Flashes"; case OptionsAction.monochromeLogo:return"Monochrome Logo";
        case OptionsAction.hideSplashTexts:return"Hide Splash Texts"; case OptionsAction.narratorHotkey:return"Narrator Hotkey";
        case OptionsAction.rotateWithMinecarts:return"Rotate with Minecarts"; case OptionsAction.highContrastBlockOutlines:return"High Contrast Block Outlines";
        default:return"";
    }
}

private bool defaultBoolean(OptionsAction a)
{
    switch(a)
    {
        case OptionsAction.allowFriendRequests,OptionsAction.inGameNotification,
             OptionsAction.subtitles,OptionsAction.directionalAudio,
             OptionsAction.improvedTransparency,OptionsAction.autoJump,
             OptionsAction.operatorItemsTab,OptionsAction.discreteScrolling,
             OptionsAction.forceUnicodeFont,OptionsAction.hideMatchedNames,
             OptionsAction.reducedDebugInfo,OptionsAction.secureChat,
             OptionsAction.highContrast,OptionsAction.hideSkyFlashes,
             OptionsAction.monochromeLogo,OptionsAction.hideSplashTexts,
             OptionsAction.rotateWithMinecarts,OptionsAction.highContrastBlockOutlines:return false;
        default:return true;
    }
}

private string integerKey(OptionsAction a)
{
    switch(a)
    {
        case OptionsAction.sharePresence:return"sharePresence"; case OptionsAction.mainHand:return"mainHand";
        case OptionsAction.musicFrequency:return"musicFrequency"; case OptionsAction.musicToast:return"musicToast";
        case OptionsAction.inactivityFpsLimit:return"inactivityFpsLimit"; case OptionsAction.guiScale:return"guiScale";
        case OptionsAction.graphicsPreset:return"graphicsPreset"; case OptionsAction.chunkBuilder:return"prioritizeChunkUpdates";
        case OptionsAction.smoothLighting:return"ao"; case OptionsAction.particles:return"particles";
        case OptionsAction.textureFiltering:return"textureFiltering"; case OptionsAction.attackIndicator:return"attackIndicator";
        case OptionsAction.sneakMode:return"sneakMode"; case OptionsAction.sprintMode:return"sprintMode";
        case OptionsAction.attackMode:return"attackMode"; case OptionsAction.useMode:return"useMode";
        case OptionsAction.chatVisibility:return"chatVisibility"; case OptionsAction.narrator:return"narrator";
        case OptionsAction.textBackgroundMode:return"textBackgroundMode"; default:return"";
    }
}

private int defaultInteger(OptionsAction a)
{
    switch(a)
    {
        case OptionsAction.sharePresence:return 2; case OptionsAction.mainHand:return 1;
        case OptionsAction.graphicsPreset:return 1; case OptionsAction.chunkBuilder:return 1;
        case OptionsAction.smoothLighting:return 2; case OptionsAction.attackIndicator:return 1;
        default:return 0;
    }
}

private int choiceCount(OptionsAction a)
{
    switch(a)
    {
        case OptionsAction.sharePresence,OptionsAction.musicFrequency,
             OptionsAction.musicToast,OptionsAction.chunkBuilder,
             OptionsAction.smoothLighting,OptionsAction.particles,
             OptionsAction.textureFiltering,OptionsAction.attackIndicator,
             OptionsAction.chatVisibility:return 3;
        case OptionsAction.graphicsPreset,OptionsAction.narrator:return 4;
        case OptionsAction.guiScale:return 5; default:return 2;
    }
}

private int guiScale(uint width,uint height)
{
    int result=1; while(result<8&&width/(result+1)>=320&&height/(result+1)>=240)++result;
    return result;
}

private int clampInt(int value,int minimum,int maximum)
{
    return value<minimum?minimum:(value>maximum?maximum:value);
}

unittest
{
    import std.file:mkdirRecurse,rmdirRecurse,tempDir;
    import std.uuid:randomUUID;
    const directory=buildPath(tempDir(),"mcd-options-"~randomUUID().toString());
    mkdirRecurse(buildPath(directory,"data")); scope(exit)rmdirRecurse(directory);
    auto s=new OptionsMenuState(directory); s.fov=92;s.masterVolume=.35f;s.clouds=false;s.invertMouse=true;
    s.activate(OptionsAction.chatColors);
    s.activate(OptionsAction.bindForward);s.captureKey('I');
    s.save();auto loaded=new OptionsMenuState(directory);
    assert(loaded.fov==92&&loaded.masterVolume==.35f&&!loaded.clouds&&loaded.invertMouse);
    assert(!loaded.boolean("chatColors",true));
    assert(loaded.key(OptionsAction.bindForward)=='I');
    assert(loaded.key(OptionsAction.bindPickBlock)==0x04);
    loaded.activate(OptionsAction.resetKeys);
    assert(loaded.key(OptionsAction.bindForward)=='W');
    loaded.open(false);loaded.activate(OptionsAction.videoMenu);
    assert(loaded.screen==OptionsScreen.video);loaded.back();assert(loaded.screen==OptionsScreen.main&&loaded.active);
}
