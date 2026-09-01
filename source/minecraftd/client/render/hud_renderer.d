module minecraftd.client.render.hud_renderer;

import core.stdc.math : ceilf;
import std.conv : to;
import minecraftd.client.render.block_renderer : BlockTextureSet;
import minecraftd.client.render.font_renderer : FontRenderer;
import minecraftd.client.render.mesh : Color, DrawLayer, FrameMesh, Vertex, appendQuad;
import minecraftd.common.math3d : Mat4, Vec2, Vec3;
import minecraftd.game.entity.player : Player;
import minecraftd.game.item.inventory : ItemId, ItemStack, itemName;

struct HudTextureSet
{
    uint hotbar;
    uint selection;
    uint heartContainer;
    uint heartContainerBlinking;
    uint heartFull;
    uint heartHalf;
    uint heartFullBlinking;
    uint heartHalfBlinking;
    uint hardcoreContainer;
    uint hardcoreContainerBlinking;
    uint hardcoreFull;
    uint hardcoreHalf;
    uint hardcoreFullBlinking;
    uint hardcoreHalfBlinking;
    uint foodEmpty;
    uint foodFull;
    uint foodHalf;
    uint air;
    uint airBursting;
    uint airEmpty;
    uint experienceBackground;
    uint experienceProgress;
}

final class HudRenderer
{
    /// The Java crosshair sprite is 15 x 15 GUI pixels and is centered on the
    /// viewport. The invert blend state supplies its black/white contrast.
    Vertex[] buildCrosshair(uint viewportWidth, uint viewportHeight) const
    {
        Vertex[] output;
        const scale=guiScale(viewportWidth,viewportHeight);
        const halfX = 15.0f*scale / cast(float) viewportWidth;
        const halfY = 15.0f*scale / cast(float) viewportHeight;
        const white = Color(1,1,1,1);
        appendQuad(output,
            Vec3(-halfX,-halfY,0), Vec3(halfX,-halfY,0),
            Vec3(halfX,halfY,0), Vec3(-halfX,halfY,0),
            Vec2(0,1), Vec2(1,1), Vec2(1,0), Vec2(0,0),
            white,white,white,white);
        return output;
    }

    void appendItem(ref FrameMesh frame, ItemStack stack, int x, int y,
        float logicalWidth, float logicalHeight,
        const BlockTextureSet blockTextures, const FontRenderer font,
        uint fontTexture, float partialTick = 0.0f) const
    {
        if(stack.empty())return;
        float pop=cast(float)stack.popTicks-partialTick;
        if(pop<0)pop=0;
        const stretch=1.0f+pop/5.0f;
        appendBlockItem(frame,stack.item,x,y,logicalWidth,logicalHeight,
            1.0f/stretch,(stretch+1.0f)*0.5f,blockTextures);
        if(stack.count>1)
        {
            const countText=to!string(stack.count);
            frame.append(font.buildText(countText,x+17-font.width(countText),y+9,
                    logicalWidth,logicalHeight,Color(1,1,1,1)),fontTexture,
                Mat4.identity(),DrawLayer.overlay);
        }
    }

    void appendSelectedItemName(ref FrameMesh frame,uint viewportWidth,
        uint viewportHeight,ItemStack selected,int remainingTicks,
        float partialTick,const Player player,const FontRenderer font,
        uint fontTexture)const
    {
        if(selected.empty()||remainingTicks<=0)return;
        const scale=guiScale(viewportWidth,viewportHeight);
        const logicalWidth=cast(float)viewportWidth/scale;
        const logicalHeight=cast(float)viewportHeight/scale;
        const label=itemName(selected.item);
        if(!label.length)return;
        float alpha=(remainingTicks-partialTick)*256.0f/10.0f;
        if(alpha>255)alpha=255;
        if(alpha<=0)return;
        const a=alpha/255.0f;
        int y=cast(int)logicalHeight-59;
        import minecraftd.world.world_settings:GameMode;
        if(player.gameMode==GameMode.creative||player.gameMode==GameMode.spectator)
            y+=14;
        const x=(cast(int)logicalWidth-font.width(label))/2;
        frame.append(font.buildText(label,x+1,y+1,logicalWidth,logicalHeight,
                Color(0,0,0,a*0.5f)),fontTexture,Mat4.identity(),DrawLayer.overlay);
        frame.append(font.buildText(label,x,y,logicalWidth,logicalHeight,
                Color(1,1,1,a)),fontTexture,Mat4.identity(),DrawLayer.overlay);
    }

    void appendSurvivalHud(ref FrameMesh frame, uint viewportWidth,
        uint viewportHeight, const Player player, const HudTextureSet textures,
        const BlockTextureSet blockTextures, const FontRenderer font,
        uint fontTexture, float partialTick) const
    {
        const scale = guiScale(viewportWidth, viewportHeight);
        const logicalWidth = cast(float) viewportWidth / scale;
        const logicalHeight = cast(float) viewportHeight / scale;
        const center = cast(int) logicalWidth / 2;

        appendSprite(frame, textures.hotbar, center - 91, cast(int) logicalHeight - 22,
            182, 22, logicalWidth, logicalHeight);
        appendSprite(frame, textures.selection,
            center - 92 + player.selectedSlot * 20,
            cast(int) logicalHeight - 23, 24, 23, logicalWidth, logicalHeight);

        foreach (slot; 0 .. player.inventory.hotbar.length)
        {
            const stack = player.inventory.hotbar[slot];
            if (stack.empty()) continue;
            // Each vanilla hotbar cell is 20 GUI pixels; its content center is
            // eleven pixels from the 182-pixel bar's left/top origin.
            const x = center - 91 + cast(int) slot * 20 + 3;
            const y = cast(int) logicalHeight - 19;
            appendItem(frame,stack,x,y,logicalWidth,logicalHeight,
                blockTextures,font,fontTexture,partialTick);
        }

        import minecraftd.world.world_settings : GameMode;
        if (player.gameMode == GameMode.creative
            || player.gameMode == GameMode.spectator)
            return;

        const heartX = center - 91;
        const statusY = cast(int) logicalHeight - 39;
        const currentHealth = cast(int) ceilf(player.health);
        const previousHealth = cast(int) ceilf(player.previousDisplayedHealth);
        const flashing = player.damageFlashTicks > 0
            && ((player.damageFlashTicks / 3) & 1) == 1;
        foreach (icon; 0 .. 10)
        {
            const x = heartX + icon * 8;
            const container = player.hardcore
                ? (flashing ? textures.hardcoreContainerBlinking
                    : textures.hardcoreContainer)
                : (flashing ? textures.heartContainerBlinking
                    : textures.heartContainer);
            appendSprite(frame, container,
                x, statusY, 9, 9, logicalWidth, logicalHeight);
            const point = icon * 2;
            if (flashing && point < previousHealth)
                appendSprite(frame, player.hardcore
                        ? (point + 1 == previousHealth
                            ? textures.hardcoreHalfBlinking : textures.hardcoreFullBlinking)
                        : (point + 1 == previousHealth
                            ? textures.heartHalfBlinking : textures.heartFullBlinking),
                    x, statusY, 9, 9, logicalWidth, logicalHeight);
            if (point < currentHealth)
                appendSprite(frame, player.hardcore
                        ? (point + 1 == currentHealth
                            ? textures.hardcoreHalf : textures.hardcoreFull)
                        : (point + 1 == currentHealth
                            ? textures.heartHalf : textures.heartFull),
                    x, statusY, 9, 9, logicalWidth, logicalHeight);
        }

        const foodRight = center + 91;
        if(player.eyeInWater||player.airSupply<Player.maximumAirSupply)
        {
            int full=cast(int)ceilf((player.airSupply-2)*10.0f
                /Player.maximumAirSupply);
            int visible=cast(int)ceilf(player.airSupply*10.0f
                /Player.maximumAirSupply);
            if(full<0)full=0; if(full>10)full=10;
            if(visible<0)visible=0; if(visible>10)visible=10;
            int bursting=visible-full;
            foreach(icon;0..full+bursting)
            {
                const x=foodRight-9-icon*8;
                const texture=icon<full?textures.air:textures.airBursting;
                appendSprite(frame,texture,x,statusY-10,9,9,
                    logicalWidth,logicalHeight);
            }
        }

        foreach (icon; 0 .. 10)
        {
            const x = foodRight - 9 - icon * 8;
            int jitter;
            if (player.hungerJiggleTicks > 0)
                jitter = ((player.survivalTicks * 312871 + icon * 17) & 3) == 0 ? 1 : 0;
            appendSprite(frame, textures.foodEmpty, x, statusY + jitter,
                9, 9, logicalWidth, logicalHeight);
            const point = icon * 2;
            if (point < player.foodLevel)
                appendSprite(frame, point + 1 == player.foodLevel
                        ? textures.foodHalf : textures.foodFull,
                    x, statusY + jitter, 9, 9, logicalWidth, logicalHeight);
        }

        // Java places the 182x5 experience meter directly above the hotbar.
        // Its fill is a horizontal crop, not a scaled sprite, so individual
        // progress pixels stay crisp at every GUI scale.
        const experienceX = center - 91;
        const experienceY = cast(int) logicalHeight - 29;
        appendSprite(frame, textures.experienceBackground, experienceX,
            experienceY, 182, 5, logicalWidth, logicalHeight);
        int progressWidth = cast(int) (player.experienceProgress * 183.0f);
        if (progressWidth < 0) progressWidth = 0;
        if (progressWidth > 182) progressWidth = 182;
        if (progressWidth > 0)
            appendSpriteCrop(frame, textures.experienceProgress, experienceX,
                experienceY, progressWidth, 182, 5,
                logicalWidth, logicalHeight);

        if (player.experienceLevel > 0)
        {
            const level = to!string(player.experienceLevel);
            frame.append(font.buildText(level,
                center - font.width(level) / 2,
                cast(int) logicalHeight - 35,
                logicalWidth, logicalHeight,
                Color(128.0f / 255.0f, 1.0f, 32.0f / 255.0f, 1.0f)),
                fontTexture, Mat4.identity(), DrawLayer.overlay);
        }
    }

private:
    static int guiScale(uint width, uint height)
    {
        int result = 1;
        while (result < 8 && width / (result + 1) >= 320
            && height / (result + 1) >= 240)
            ++result;
        return result;
    }

    static void appendSprite(ref FrameMesh frame, uint texture, int x, int y,
        int spriteWidth, int spriteHeight, float logicalWidth, float logicalHeight)
    {
        Vertex[] output;
        const left = cast(float) x / logicalWidth * 2.0f - 1.0f;
        const right = cast(float) (x + spriteWidth) / logicalWidth * 2.0f - 1.0f;
        const top = 1.0f - cast(float) y / logicalHeight * 2.0f;
        const bottom = 1.0f - cast(float) (y + spriteHeight) / logicalHeight * 2.0f;
        const white = Color(1, 1, 1, 1);
        appendQuad(output,
            Vec3(left, bottom, 0), Vec3(right, bottom, 0),
            Vec3(right, top, 0), Vec3(left, top, 0),
            Vec2(0,1), Vec2(1,1), Vec2(1,0), Vec2(0,0),
            white, white, white, white);
        frame.append(output, texture, Mat4.identity(), DrawLayer.overlay);
    }

    static void appendSpriteCrop(ref FrameMesh frame, uint texture, int x,
        int y, int visibleWidth, int sourceWidth, int spriteHeight,
        float logicalWidth, float logicalHeight)
    {
        Vertex[] output;
        const left = cast(float) x / logicalWidth * 2.0f - 1.0f;
        const right = cast(float) (x + visibleWidth) / logicalWidth * 2.0f - 1.0f;
        const top = 1.0f - cast(float) y / logicalHeight * 2.0f;
        const bottom = 1.0f - cast(float) (y + spriteHeight) / logicalHeight * 2.0f;
        const u1 = cast(float) visibleWidth / sourceWidth;
        const white = Color(1, 1, 1, 1);
        appendQuad(output,
            Vec3(left, bottom, 0), Vec3(right, bottom, 0),
            Vec3(right, top, 0), Vec3(left, top, 0),
            Vec2(0,1), Vec2(u1,1), Vec2(u1,0), Vec2(0,0),
            white, white, white, white);
        frame.append(output, texture, Mat4.identity(), DrawLayer.overlay);
    }

    static void appendBlockItem(ref FrameMesh frame, ItemId item, int x, int y,
        float logicalWidth, float logicalHeight, float scaleX, float scaleY,
        const BlockTextureSet textures)
    {
        uint top;
        uint side;
        final switch (item)
        {
            case ItemId.none: return;
            case ItemId.grassBlock:
                top = textures.grassTop; side = textures.grassSide; break;
            case ItemId.dirt:
                top = side = textures.dirt; break;
            case ItemId.stone:
                top = side = textures.stone; break;
            case ItemId.obsidian:
                top = side = textures.obsidian; break;
            case ItemId.netherrack:
                top = side = textures.netherrack; break;
            case ItemId.bricks: top = side = textures.bricks; break;
            case ItemId.oakPlanks: top = side = textures.oakPlanks; break;
            case ItemId.sprucePlanks: top = side = textures.sprucePlanks; break;
            case ItemId.birchPlanks: top = side = textures.birchPlanks; break;
            case ItemId.junglePlanks: top = side = textures.junglePlanks; break;
            case ItemId.acaciaPlanks: top = side = textures.acaciaPlanks; break;
            case ItemId.darkOakPlanks: top = side = textures.darkOakPlanks; break;
            case ItemId.mangrovePlanks: top = side = textures.mangrovePlanks; break;
            case ItemId.cherryPlanks: top = side = textures.cherryPlanks; break;
            case ItemId.bambooPlanks: top = side = textures.bambooPlanks; break;
            case ItemId.paleOakPlanks: top = side = textures.paleOakPlanks; break;
            case ItemId.crimsonPlanks: top = side = textures.crimsonPlanks; break;
            case ItemId.warpedPlanks: top = side = textures.warpedPlanks; break;
            case ItemId.cobblestone: top = side = textures.cobblestone; break;
            case ItemId.glass: top = side = textures.glass; break;
            case ItemId.bedrock: top = side = textures.bedrock; break;
            case ItemId.flintAndSteel:
            {
                const centerX = x + 8.0f;
                const centerY = y + 8.0f;
                float px(float value) { return centerX + (value-centerX)*scaleX; }
                float py(float value) { return centerY + (value-centerY)*scaleY; }
                Vec3 ndc(float pixelX,float pixelY)
                {
                    return Vec3(pixelX/logicalWidth*2.0f-1.0f,
                        1.0f-pixelY/logicalHeight*2.0f,0);
                }
                Vertex[] output;
                const color=Color(1,1,1,1);
                appendQuad(output,ndc(px(x),py(y+16)),ndc(px(x+16),py(y+16)),
                    ndc(px(x+16),py(y)),ndc(px(x),py(y)),
                    Vec2(0,1),Vec2(1,1),Vec2(1,0),Vec2(0,0),
                    color,color,color,color);
                frame.append(output,textures.flintAndSteel,Mat4.identity(),
                    DrawLayer.overlay);
                return;
            }
        }
        const centerX = x + 8.0f;
        const centerY = y + 8.0f;
        float px(float value) { return centerX + (value - centerX) * scaleX; }
        float py(float value) { return centerY + (value - centerY) * scaleY; }
        Vec3 ndc(float pixelX, float pixelY)
        {
            return Vec3(pixelX / logicalWidth * 2.0f - 1.0f,
                1.0f - pixelY / logicalHeight * 2.0f, 0);
        }
        void face(uint texture, Vec2[4] points, Color shade)
        {
            Vertex[] output;
            appendQuad(output,
                ndc(px(points[0].x),py(points[0].y)),
                ndc(px(points[1].x),py(points[1].y)),
                ndc(px(points[2].x),py(points[2].y)),
                ndc(px(points[3].x),py(points[3].y)),
                Vec2(0,1),Vec2(1,1),Vec2(1,0),Vec2(0,0),
                shade,shade,shade,shade);
            frame.append(output, texture, Mat4.identity(), DrawLayer.overlay);
        }
        // A full 16x16 symmetric projection: eight pixels on either side of
        // the slot center and equal four-pixel slopes on the top diamond.
        face(top, [Vec2(x+8,y),Vec2(x+16,y+4),Vec2(x+8,y+8),Vec2(x,y+4)],
            Color(1,1,1,1));
        face(side, [Vec2(x,y+4),Vec2(x+8,y+8),Vec2(x+8,y+16),Vec2(x,y+12)],
            Color(0.65f,0.65f,0.65f,1));
        face(side, [Vec2(x+8,y+8),Vec2(x+16,y+4),Vec2(x+16,y+12),Vec2(x+8,y+16)],
            Color(0.8f,0.8f,0.8f,1));
    }
}
