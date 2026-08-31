module minecraftd.client.menu.inventory_menu;

import core.stdc.math:atanf;
import minecraftd.client.render.block_renderer:BlockTextureSet;
import minecraftd.client.render.font_renderer:FontRenderer;
import minecraftd.client.render.hud_renderer:HudRenderer;
import minecraftd.client.render.player_renderer:PlayerRenderer,SkinLayers;
import minecraftd.client.render.mesh:Color,DrawLayer,FrameMesh,Vertex,appendQuad;
import minecraftd.common.math3d:Mat4,Vec2,Vec3;
import minecraftd.game.entity.player:Player;
import minecraftd.game.item.inventory:Inventory,ItemStack,itemCategory,itemName;

struct InventoryTextureSet
{
    uint background;
    uint white;
    uint tooltipBackground;
    uint tooltipFrame;
    uint slotHighlightBack;
    uint slotHighlightFront;
}

final class InventoryMenuState
{
    bool active;
    uint lastClickMilliseconds;
    int lastClickSlot=-1;
    int lastClickButton=-1;

    void open(){active=true;lastClickSlot=-1;}
    void close(){active=false;lastClickSlot=-1;}

    bool doubleClick(int slot,int button,uint now)
    {
        const result=slot>=0&&slot==lastClickSlot&&button==lastClickButton
            && now-lastClickMilliseconds<=250;
        lastClickSlot=slot;
        lastClickButton=button;
        lastClickMilliseconds=now;
        return result;
    }
}

final class InventoryMenuRenderer
{
    enum int imageWidth=176;
    enum int imageHeight=166;

    int hitSlot(uint viewportWidth,uint viewportHeight,int mouseX,int mouseY)const
    {
        const scale=guiScale(viewportWidth,viewportHeight);
        const width=cast(int)viewportWidth/scale;
        const height=cast(int)viewportHeight/scale;
        const left=(width-imageWidth)/2;
        const top=(height-imageHeight)/2;
        const x=mouseX/scale;
        const y=mouseY/scale;
        foreach(row;0..3)foreach(column;0..9)
        {
            const slotX=left+8+column*18;
            const slotY=top+84+row*18;
            if(x>=slotX&&x<slotX+18&&y>=slotY&&y<slotY+18)
                return row*9+column;
        }
        foreach(column;0..9)
        {
            const slotX=left+8+column*18;
            const slotY=top+142;
            if(x>=slotX&&x<slotX+18&&y>=slotY&&y<slotY+18)
                return Inventory.storageSize+column;
        }
        return -1;
    }

    bool outside(uint viewportWidth,uint viewportHeight,int mouseX,int mouseY)const
    {
        const scale=guiScale(viewportWidth,viewportHeight);
        const width=cast(int)viewportWidth/scale;
        const height=cast(int)viewportHeight/scale;
        const left=(width-imageWidth)/2;
        const top=(height-imageHeight)/2;
        const x=mouseX/scale;
        const y=mouseY/scale;
        return x<left||x>=left+imageWidth||y<top||y>=top+imageHeight;
    }

    void append(ref FrameMesh frame,uint viewportWidth,uint viewportHeight,
        int mouseX,int mouseY,const Inventory inventory,
        const InventoryTextureSet textures,const BlockTextureSet blockTextures,
        const HudRenderer itemRenderer,const FontRenderer font,uint fontTexture,
        float partialTick,PlayerRenderer playerRenderer,
        const Player player,uint playerTexture,float ageInTicks,
        bool slimArms = false)const
    {
        const scale=guiScale(viewportWidth,viewportHeight);
        const logicalWidth=cast(float)viewportWidth/scale;
        const logicalHeight=cast(float)viewportHeight/scale;
        const left=(cast(int)logicalWidth-imageWidth)/2;
        const top=(cast(int)logicalHeight-imageHeight)/2;
        const logicalMouseX=mouseX/scale;
        const logicalMouseY=mouseY/scale;

        appendSolid(frame,textures.white,0,0,cast(int)logicalWidth,
            cast(int)logicalHeight,logicalWidth,logicalHeight,
            Color(0.04f,0.04f,0.04f,0.72f));
        appendSprite(frame,textures.background,left,top,imageWidth,imageHeight,
            logicalWidth,logicalHeight);
        appendPlayerPreview(frame,left,top,logicalMouseX,logicalMouseY,
            logicalWidth,logicalHeight,playerRenderer,player,playerTexture,
            partialTick,ageInTicks,slimArms);

        const hovered=hitSlot(viewportWidth,viewportHeight,mouseX,mouseY);
        if(hovered>=0)
        {
            int slotX,slotY;
            slotPosition(hovered,left,top,slotX,slotY);
            appendFullSprite(frame,textures.slotHighlightBack,slotX,slotY,
                16,16,logicalWidth,logicalHeight);
        }

        foreach(index;0..Inventory.slotCount)
        {
            const stack=inventory.slot(index);
            if(stack.empty())continue;
            int x,y;
            slotPosition(index,left,top,x,y);
            itemRenderer.appendItem(frame,stack,x,y,logicalWidth,logicalHeight,
                blockTextures,font,fontTexture,partialTick);
        }

        if(hovered>=0)
        {
            int slotX,slotY;
            slotPosition(hovered,left,top,slotX,slotY);
            appendFullSprite(frame,textures.slotHighlightFront,slotX,slotY,
                16,16,logicalWidth,logicalHeight);
        }

        if(!inventory.carried.empty())
            itemRenderer.appendItem(frame,inventory.carried,logicalMouseX-8,
                logicalMouseY-8,logicalWidth,logicalHeight,blockTextures,font,
                fontTexture,partialTick);
        else if(hovered>=0&&!inventory.slot(hovered).empty())
            appendTooltip(frame,inventory.slot(hovered),logicalMouseX,
                logicalMouseY,logicalWidth,logicalHeight,
                textures.tooltipBackground,textures.tooltipFrame,font,fontTexture);
    }

    void appendPlayerShowcase(ref FrameMesh frame,int boxX,int boxY,
        int boxWidth,int boxHeight,int mouseX,int mouseY,float width,float height,
        PlayerRenderer renderer,const Player player,uint texture,
        float partialTick,float ageInTicks,bool slimArms = false)const
    {
        appendPlayerModel(frame,cast(float)boxX+boxWidth*0.5f,
            cast(float)boxY+boxHeight*0.4f,cast(float)boxY+boxHeight-8.0f,
            boxHeight/3.73f,mouseX,mouseY,width,height,renderer,player,
            texture,partialTick,ageInTicks,slimArms);
    }

private:
    static void appendPlayerPreview(ref FrameMesh frame,int left,int top,
        int mouseX,int mouseY,float width,float height,
        PlayerRenderer renderer,const Player player,uint texture,
        float partialTick,float ageInTicks,bool slimArms)
    {
        // Exact 26.2 InventoryScreen preview rectangle is (26,8)-(75,78)
        // with scale 30 and atan mouse response divided by 40.
        appendPlayerModel(frame,cast(float)left+50.5f,cast(float)top+43.0f,
            cast(float)top+76.0f,30.0f,mouseX,mouseY,width,height,renderer,
            player,texture,partialTick,ageInTicks,slimArms);
    }

    static void appendPlayerModel(ref FrameMesh frame,float centerX,
        float centerY,float feetY,float modelScale,int mouseX,int mouseY,
        float width,float height,PlayerRenderer renderer,const Player player,
        uint texture,float partialTick,float ageInTicks,bool slimArms)
    {
        const horizontal=atanf((centerX-mouseX)/40.0f);
        const vertical=atanf((centerY-mouseY)/40.0f);
        const horizontalDegrees=horizontal*20.0f;
        const verticalDegrees=vertical*20.0f;
        // Java's GUI entity renderer adds a separate 180-degree display
        // quaternion. Our screen-space projection does not, so its equivalent
        // player-model yaw is zero plus the mouse-driven body turn.
        auto geometry=renderer.buildSteve(Vec3.init,horizontalDegrees,
            horizontalDegrees,-verticalDegrees,
            player.interpolatedWalkAnimationPosition(partialTick),
            player.interpolatedWalkAnimationSpeed(partialTick),
            player.interpolatedAttackProgress(partialTick),player.crouching,
            ageInTicks,SkinLayers.fromBits(player.skinParts),false,true,false,
            slimArms);
        const tilt=Mat4.translation(Vec3(0,-0.9f,0))
            *Mat4.rotationX(verticalDegrees*3.14159265f/180.0f)
            *Mat4.translation(Vec3(0,0.9f,0));
        foreach(ref vertex;geometry)
        {
            const point=tilt.transformPoint(Vec3(vertex.position[0],
                vertex.position[1],vertex.position[2]));
            const screenX=centerX+point.x*modelScale;
            const screenY=feetY-point.y*modelScale;
            vertex.position=[screenX/width*2.0f-1.0f,
                1.0f-screenY/height*2.0f,0.5f+point.z*0.05f];
        }
        frame.append(geometry,texture,Mat4.identity(),DrawLayer.viewModel);
    }

    static int guiScale(uint width,uint height)
    {
        int result=1;
        while(result<8&&width/(result+1)>=320&&height/(result+1)>=240)++result;
        return result;
    }

    static void slotPosition(int index,int left,int top,out int x,out int y)
    {
        if(index<Inventory.storageSize)
        {
            x=left+8+(index%9)*18;
            y=top+84+(index/9)*18;
        }
        else
        {
            x=left+8+(index-Inventory.storageSize)*18;
            y=top+142;
        }
    }

    static void appendTooltip(ref FrameMesh frame,ItemStack stack,int mouseX,
        int mouseY,float width,float height,uint background,uint frameTexture,
        const FontRenderer font,uint fontTexture)
    {
        const first=itemName(stack.item);
        const second=itemCategory(stack.item);
        int tooltipWidth=font.width(first);
        if(font.width(second)>tooltipWidth)tooltipWidth=font.width(second);
        const tooltipHeight=second.length?22:11;
        int x=mouseX+12;
        int y=mouseY-12;
        if(x+tooltipWidth+6>width)x=mouseX-12-tooltipWidth-6;
        if(y+tooltipHeight+8>height)y=cast(int)height-tooltipHeight-8;
        if(y<4)y=4;
        appendNineSlice(frame,background,x-3,y-4,tooltipWidth+6,
            tooltipHeight+8,9,width,height);
        appendNineSlice(frame,frameTexture,x-3,y-4,tooltipWidth+6,
            tooltipHeight+8,10,width,height);
        frame.append(font.buildText(first,x,y,width,height,Color(1,1,1,1)),
            fontTexture,Mat4.identity(),DrawLayer.overlay);
        if(second.length)
            frame.append(font.buildText(second,x,y+11,width,height,
                    Color(85.0f/255.0f,85.0f/255.0f,1,1)),fontTexture,
                Mat4.identity(),DrawLayer.overlay);
    }

    static void appendNineSlice(ref FrameMesh frame,uint texture,int x,int y,
        int w,int h,int border,float width,float height)
    {
        // Both vanilla tooltip sprites are 100x100 with metadata-defined
        // nine-slice borders (background 9, frame 10).
        const targetBorder=border<w/2?border:w/2;
        const targetBorderY=border<h/2?border:h/2;
        immutable int[4] xs=[x,x+targetBorder,x+w-targetBorder,x+w];
        immutable int[4] ys=[y,y+targetBorderY,y+h-targetBorderY,y+h];
        immutable float[4] us=[0,cast(float)border/100.0f,
            1.0f-cast(float)border/100.0f,1];
        immutable float[4] vs=[0,cast(float)border/100.0f,
            1.0f-cast(float)border/100.0f,1];
        Vertex[] output;
        const color=Color(1,1,1,1);
        foreach(row;0..3)foreach(column;0..3)
        {
            const left=cast(float)xs[column]/width*2-1;
            const right=cast(float)xs[column+1]/width*2-1;
            const top=1-cast(float)ys[row]/height*2;
            const bottom=1-cast(float)ys[row+1]/height*2;
            appendQuad(output,Vec3(left,bottom,0),Vec3(right,bottom,0),
                Vec3(right,top,0),Vec3(left,top,0),
                Vec2(us[column],vs[row+1]),Vec2(us[column+1],vs[row+1]),
                Vec2(us[column+1],vs[row]),Vec2(us[column],vs[row]),
                color,color,color,color);
        }
        frame.append(output,texture,Mat4.identity(),DrawLayer.overlay);
    }

    static void appendSprite(ref FrameMesh frame,uint texture,int x,int y,
        int spriteWidth,int spriteHeight,float width,float height)
    {
        Vertex[] output;
        const left=cast(float)x/width*2-1;
        const right=cast(float)(x+spriteWidth)/width*2-1;
        const top=1-cast(float)y/height*2;
        const bottom=1-cast(float)(y+spriteHeight)/height*2;
        const white=Color(1,1,1,1);
        appendQuad(output,Vec3(left,bottom,0),Vec3(right,bottom,0),
            Vec3(right,top,0),Vec3(left,top,0),Vec2(0,1),Vec2(1,1),
            Vec2(1,0),Vec2(0,0),white,white,white,white);
        // inventory.png is a 256x256 atlas; the screen occupies only its
        // 176x166 top-left region. Full-atlas UVs compressed the whole UI.
        foreach(ref vertex;output)
        {
            vertex.uv[0]*=176.0f/256.0f;
            vertex.uv[1]*=166.0f/256.0f;
        }
        frame.append(output,texture,Mat4.identity(),DrawLayer.overlay);
    }

    static void appendFullSprite(ref FrameMesh frame,uint texture,int x,int y,
        int spriteWidth,int spriteHeight,float width,float height)
    {
        Vertex[] output;
        const left=cast(float)x/width*2-1;
        const right=cast(float)(x+spriteWidth)/width*2-1;
        const top=1-cast(float)y/height*2;
        const bottom=1-cast(float)(y+spriteHeight)/height*2;
        const white=Color(1,1,1,1);
        appendQuad(output,Vec3(left,bottom,0),Vec3(right,bottom,0),
            Vec3(right,top,0),Vec3(left,top,0),Vec2(0,1),Vec2(1,1),
            Vec2(1,0),Vec2(0,0),white,white,white,white);
        frame.append(output,texture,Mat4.identity(),DrawLayer.overlay);
    }

    static void appendSolid(ref FrameMesh frame,uint texture,int x,int y,int w,
        int h,float width,float height,Color color)
    {
        Vertex[] output;
        const left=cast(float)x/width*2-1;
        const right=cast(float)(x+w)/width*2-1;
        const top=1-cast(float)y/height*2;
        const bottom=1-cast(float)(y+h)/height*2;
        appendQuad(output,Vec3(left,bottom,0),Vec3(right,bottom,0),
            Vec3(right,top,0),Vec3(left,top,0),Vec2(0,1),Vec2(1,1),
            Vec2(1,0),Vec2(0,0),color,color,color,color);
        frame.append(output,texture,Mat4.identity(),DrawLayer.overlay);
    }
}

unittest
{
    auto renderer=new InventoryMenuRenderer();
    scope(exit)destroy(renderer);
    // At 854x480 the auto GUI scale is two, so physical coordinates double.
    assert(renderer.hitSlot(854,480,(125+8)*2,(37+84)*2)==0);
}
