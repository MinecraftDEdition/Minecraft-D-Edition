module minecraftd.client.menu.inventory_menu;

import core.stdc.math:atanf;
import std.ascii : toLower;
import minecraftd.client.render.block_renderer:BlockTextureSet;
import minecraftd.client.render.font_renderer:FontRenderer;
import minecraftd.client.render.hud_renderer:HudRenderer;
import minecraftd.client.render.player_renderer:PlayerRenderer,SkinLayers;
import minecraftd.client.render.mesh:Color,DrawLayer,FrameMesh,Vertex,appendQuad;
import minecraftd.common.math3d:Mat4,Vec2,Vec3;
import minecraftd.client.input.text_edit_state : TextEditState;
import minecraftd.game.entity.player:Player;
import minecraftd.game.item.inventory:CreativeItemGroup,Inventory,ItemId,
    ItemStack,creativeCatalog,creativeItems,itemCategory,itemName;
import minecraftd.platform.input:GamepadButton,GamepadState,Point;

struct InventoryTextureSet
{
    uint background;
    uint white;
    uint tooltipBackground;
    uint tooltipFrame;
    uint slotHighlightBack;
    uint slotHighlightFront;
    uint controllerCursor;
    uint creativeItemsBackground;
    uint creativeSearchBackground;
    uint creativeInventoryBackground;
    uint scroller;
    uint scrollerDisabled;
    uint[7] topSelected;
    uint[7] topUnselected;
    uint[7] bottomSelected;
    uint[7] bottomUnselected;
    uint[14] creativeTabIcons;
    bool[14] creativeTabCubeIcons;
}

enum CreativeTab : ubyte
{
    buildingBlocks,
    coloredBlocks,
    naturalBlocks,
    functionalBlocks,
    redstoneBlocks,
    savedHotbars,
    searchItems,
    toolsAndUtilities,
    combat,
    foodAndDrinks,
    ingredients,
    spawnEggs,
    operatorUtilities,
    survivalInventory,
}

string creativeTabName(CreativeTab tab)
{
    final switch(tab)
    {
        case CreativeTab.buildingBlocks:return "Building Blocks";
        case CreativeTab.coloredBlocks:return "Colored Blocks";
        case CreativeTab.naturalBlocks:return "Natural Blocks";
        case CreativeTab.functionalBlocks:return "Functional Blocks";
        case CreativeTab.redstoneBlocks:return "Redstone Blocks";
        case CreativeTab.savedHotbars:return "Saved Hotbars";
        case CreativeTab.searchItems:return "Search Items";
        case CreativeTab.toolsAndUtilities:return "Tools & Utilities";
        case CreativeTab.combat:return "Combat";
        case CreativeTab.foodAndDrinks:return "Food & Drinks";
        case CreativeTab.ingredients:return "Ingredients";
        case CreativeTab.spawnEggs:return "Spawn Eggs";
        case CreativeTab.operatorUtilities:return "Operator Utilities";
        case CreativeTab.survivalInventory:return "Survival Inventory";
    }
}

final class InventoryMenuState
{
    bool active;
    uint lastClickMilliseconds;
    int lastClickSlot=-1;
    int lastClickButton=-1;
    private float controllerCursorX;
    private float controllerCursorY;
    private bool controllerCursorInitialized;
    CreativeTab creativeTab=CreativeTab.buildingBlocks;
    string searchInput;
    TextEditState searchEdit;
    int creativeScrollRow;

    void open(){active=true;lastClickSlot=-1;controllerCursorInitialized=false;}
    void close()
    {
        active=false;
        lastClickSlot=-1;
        searchInput="";
        searchEdit=TextEditState.init;
        creativeScrollRow=0;
    }

    void selectCreativeTab(CreativeTab tab)
    {
        creativeTab=tab;
        creativeScrollRow=0;
        if(tab==CreativeTab.searchItems)searchEdit.moveToEnd(searchInput);
    }

    bool searchActive()const{return creativeTab==CreativeTab.searchItems;}
    bool searchHasSelection()const{return searchEdit.hasSelection;}
    string selectedSearchText()const{return searchEdit.selectedText(searchInput);}
    void selectAllSearch(){searchEdit.selectAll(searchInput);}
    void setSearchCursor(size_t position,bool selecting=false)
    {searchEdit.setCursor(searchInput,position,selecting);}
    void moveSearchCursor(int amount,bool selecting=false)
    {searchEdit.moveCursor(searchInput,amount,selecting);}
    void moveSearchStart(bool selecting=false)
    {searchEdit.moveToStart(searchInput,selecting);}
    void moveSearchEnd(bool selecting=false)
    {searchEdit.moveToEnd(searchInput,selecting);}
    void backspaceSearch(){searchEdit.backspace(searchInput);creativeScrollRow=0;}
    void deleteSearch(){searchEdit.deleteForward(searchInput);creativeScrollRow=0;}
    void cutSearch()
    {searchEdit.eraseSelection(searchInput);creativeScrollRow=0;}
    void pasteSearch(string value)
    {
        foreach(character;value)
            if(character>=32&&character<127)
                searchEdit.insert(searchInput,character,64);
        creativeScrollRow=0;
    }

    void typeSearch(wstring value)
    {
        foreach(character;value)
            if(character>=32&&character<127)
                searchEdit.insert(searchInput,cast(char)character,64);
        creativeScrollRow=0;
    }

    ItemId[] visibleCreativeItems()const
    {
        ItemId[] result;
        if(creativeTab==CreativeTab.searchItems)
        {
            foreach(item;creativeCatalog)
                if(searchInput.length==0||containsIgnoreCase(itemName(item),searchInput))
                    result~=item;
            return result;
        }
        if(creativeTab==CreativeTab.savedHotbars
            ||creativeTab==CreativeTab.survivalInventory)return result;
        const ordinal=cast(int)creativeTab;
        const group=ordinal<=cast(int)CreativeTab.redstoneBlocks
            ?cast(CreativeItemGroup)ordinal
            :cast(CreativeItemGroup)(ordinal-2);
        return creativeItems(group);
    }

    int maximumCreativeScrollRow()const
    {
        const count=visibleCreativeItems.length;
        const rows=cast(int)((count+8)/9);
        return rows>5?rows-5:0;
    }

    void scrollCreative(int wheelSteps)
    {
        creativeScrollRow-=wheelSteps;
        const maximum=maximumCreativeScrollRow;
        if(creativeScrollRow<0)creativeScrollRow=0;
        if(creativeScrollRow>maximum)creativeScrollRow=maximum;
    }

    bool doubleClick(int slot,int button,uint now)
    {
        const result=slot>=0&&slot==lastClickSlot&&button==lastClickButton
            && now-lastClickMilliseconds<=250;
        lastClickSlot=slot;
        lastClickButton=button;
        lastClickMilliseconds=now;
        return result;
    }

    void updateControllerCursor(float stickX,float stickY,GamepadState gamepad,
        float frameSeconds,uint viewportWidth,uint viewportHeight)
    {
        if(!controllerCursorInitialized)
        {
            const scale=inventoryGuiScale(viewportWidth,viewportHeight);
            const logicalWidth=cast(int)viewportWidth/scale;
            const logicalHeight=cast(int)viewportHeight/scale;
            const left=(logicalWidth-InventoryMenuRenderer.imageWidth)/2;
            const top=(logicalHeight-InventoryMenuRenderer.imageHeight)/2;
            controllerCursorX=(left+16)*scale;
            controllerCursorY=(top+92)*scale;
            controllerCursorInitialized=true;
        }
        float x=stickX;
        float y=-stickY;
        if(gamepad.down(GamepadButton.dpadLeft))x=-1;
        else if(gamepad.down(GamepadButton.dpadRight))x=1;
        if(gamepad.down(GamepadButton.dpadUp))y=-1;
        else if(gamepad.down(GamepadButton.dpadDown))y=1;
        const shortest=viewportWidth<viewportHeight?viewportWidth:viewportHeight;
        const speed=cast(float)shortest*0.9f;
        controllerCursorX+=x*speed*frameSeconds;
        controllerCursorY+=y*speed*frameSeconds;
        if(controllerCursorX<0)controllerCursorX=0;
        if(controllerCursorY<0)controllerCursorY=0;
        if(controllerCursorX>=viewportWidth)controllerCursorX=viewportWidth-1;
        if(controllerCursorY>=viewportHeight)controllerCursorY=viewportHeight-1;
    }

    Point controllerCursor() const
    {
        Point result;
        result.x=cast(int)controllerCursorX;
        result.y=cast(int)controllerCursorY;
        return result;
    }
}

private bool containsIgnoreCase(string value,string query)
{
    if(query.length==0)return true;
    if(query.length>value.length)return false;
    foreach(start;0..value.length-query.length+1)
    {
        bool matches=true;
        foreach(offset;0..query.length)
            if(toLower(value[start+offset])!=toLower(query[offset]))
            {matches=false;break;}
        if(matches)return true;
    }
    return false;
}

final class InventoryMenuRenderer
{
    enum int imageWidth=176;
    enum int imageHeight=166;
    enum int creativeImageWidth=195;
    enum int creativeImageHeight=136;
    enum int creativeCatalogBase=100;
    enum int creativeTrashSlot=250;

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
            if(x>=slotX&&x<slotX+16&&y>=slotY&&y<slotY+16)
                return row*9+column;
        }
        foreach(column;0..9)
        {
            const slotX=left+8+column*18;
            const slotY=top+142;
            if(x>=slotX&&x<slotX+16&&y>=slotY&&y<slotY+16)
                return Inventory.storageSize+column;
        }
        return -1;
    }

    int hitCreativeSlot(uint viewportWidth,uint viewportHeight,int mouseX,
        int mouseY,const InventoryMenuState state)const
    {
        const scale=guiScale(viewportWidth,viewportHeight);
        const width=cast(int)viewportWidth/scale;
        const height=cast(int)viewportHeight/scale;
        const left=(width-creativeImageWidth)/2;
        const top=(height-creativeImageHeight)/2;
        const x=mouseX/scale;
        const y=mouseY/scale;
        if(state.creativeTab==CreativeTab.survivalInventory)
        {
            foreach(row;0..3)foreach(column;0..9)
                if(x>=left+9+column*18&&x<left+25+column*18
                    &&y>=top+54+row*18&&y<top+70+row*18)
                    return row*9+column;
            foreach(column;0..9)
                if(x>=left+9+column*18&&x<left+25+column*18
                    &&y>=top+112&&y<top+128)
                    return Inventory.storageSize+column;
            if(x>=left+173&&x<left+189&&y>=top+112&&y<top+128)
                return creativeTrashSlot;
            return -1;
        }
        foreach(row;0..5)foreach(column;0..9)
            if(x>=left+9+column*18&&x<left+25+column*18
                &&y>=top+18+row*18&&y<top+34+row*18)
            {
                const index=state.creativeScrollRow*9+row*9+column;
                return index<state.visibleCreativeItems.length
                    ?creativeCatalogBase+index:-1;
            }
        foreach(column;0..9)
            if(x>=left+9+column*18&&x<left+25+column*18
                &&y>=top+112&&y<top+128)
                return Inventory.storageSize+column;
        return -1;
    }

    int creativeTabAt(uint viewportWidth,uint viewportHeight,int mouseX,
        int mouseY)const
    {
        const scale=guiScale(viewportWidth,viewportHeight);
        const width=cast(int)viewportWidth/scale;
        const height=cast(int)viewportHeight/scale;
        const left=(width-creativeImageWidth)/2;
        const top=(height-creativeImageHeight)/2;
        const x=mouseX/scale;
        const y=mouseY/scale;
        foreach(index;0..7)
        {
            const tabX=creativeTabX(left,index);
            if(x>=tabX&&x<tabX+26
                &&y>=top-28&&y<top+4)return index;
        }
        foreach(index;0..7)
        {
            const tabX=creativeTabX(left,index);
            if(index!=5&&x>=tabX&&x<tabX+26
                &&y>=top+132&&y<top+164)return 7+index;
        }
        return -1;
    }

    bool creativeSearchAt(uint viewportWidth,uint viewportHeight,int mouseX,
        int mouseY)const
    {
        const scale=guiScale(viewportWidth,viewportHeight);
        const width=cast(int)viewportWidth/scale;
        const height=cast(int)viewportHeight/scale;
        const left=(width-creativeImageWidth)/2;
        const top=(height-creativeImageHeight)/2;
        const x=mouseX/scale;
        const y=mouseY/scale;
        return x>=left+81&&x<left+170&&y>=top+5&&y<top+16;
    }

    size_t creativeSearchCursorAt(uint viewportWidth,uint viewportHeight,
        int mouseX,const InventoryMenuState state,const FontRenderer font)const
    {
        const scale=guiScale(viewportWidth,viewportHeight);
        const width=cast(int)viewportWidth/scale;
        const left=(width-creativeImageWidth)/2;
        const target=mouseX/scale-(left+82);
        if(target<=0)return 0;
        int previous;
        foreach(position;0..state.searchInput.length)
        {
            const next=font.width(state.searchInput[0..position+1]);
            if(target<previous+(next-previous)/2)return position;
            previous=next;
        }
        return state.searchInput.length;
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


    bool outsideCreative(uint viewportWidth,uint viewportHeight,int mouseX,
        int mouseY)const
    {
        const scale=guiScale(viewportWidth,viewportHeight);
        const width=cast(int)viewportWidth/scale;
        const height=cast(int)viewportHeight/scale;
        const left=(width-creativeImageWidth)/2;
        const top=(height-creativeImageHeight)/2;
        const x=mouseX/scale;
        const y=mouseY/scale;
        return x<left||x>=left+creativeImageWidth||y<top-28||y>=top+164;
    }

    void append(ref FrameMesh frame,uint viewportWidth,uint viewportHeight,
        int mouseX,int mouseY,const Inventory inventory,
        const InventoryTextureSet textures,const BlockTextureSet blockTextures,
        const HudRenderer itemRenderer,const FontRenderer font,uint fontTexture,
        float partialTick,PlayerRenderer playerRenderer,
        const Player player,uint playerTexture,float ageInTicks,
        bool slimArms = false,bool drawControllerCursor = false,
        const InventoryMenuState state=null,bool creative=false)const
    {
        if(creative&&state !is null)
        {
            appendCreative(frame,viewportWidth,viewportHeight,mouseX,mouseY,
                inventory,textures,blockTextures,itemRenderer,font,fontTexture,
                partialTick,playerRenderer,player,playerTexture,ageInTicks,
                slimArms,drawControllerCursor,state);
            return;
        }
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
            appendSlotHighlight(frame,textures.slotHighlightBack,slotX,slotY,
                logicalWidth,logicalHeight);
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
            appendSlotHighlight(frame,textures.slotHighlightFront,slotX,slotY,
                logicalWidth,logicalHeight);
        }

        if(!inventory.carried.empty())
        {
            const carried=ItemStack(inventory.carried.item,
                inventory.carried.count,0);
            itemRenderer.appendItem(frame,carried,logicalMouseX-8,
                logicalMouseY-8,logicalWidth,logicalHeight,blockTextures,font,
                fontTexture,partialTick);
        }
        else if(hovered>=0&&!inventory.slot(hovered).empty())
            appendTooltip(frame,inventory.slot(hovered),logicalMouseX,
                logicalMouseY,logicalWidth,logicalHeight,
                textures.tooltipBackground,textures.tooltipFrame,font,fontTexture);
        if(drawControllerCursor)
        {
            const cursorSize=(29+scale-1)/scale;
            appendFullSprite(frame,textures.controllerCursor,
                logicalMouseX-cursorSize/2,logicalMouseY-cursorSize/2,
                cursorSize,cursorSize,logicalWidth,logicalHeight);
        }
    }

    void appendCreative(ref FrameMesh frame,uint viewportWidth,
        uint viewportHeight,int mouseX,int mouseY,const Inventory inventory,
        const InventoryTextureSet textures,const BlockTextureSet blockTextures,
        const HudRenderer itemRenderer,const FontRenderer font,uint fontTexture,
        float partialTick,PlayerRenderer playerRenderer,const Player player,
        uint playerTexture,float ageInTicks,bool slimArms,
        bool drawControllerCursor,const InventoryMenuState state)const
    {
        const scale=guiScale(viewportWidth,viewportHeight);
        const logicalWidth=cast(float)viewportWidth/scale;
        const logicalHeight=cast(float)viewportHeight/scale;
        const left=(cast(int)logicalWidth-creativeImageWidth)/2;
        const top=(cast(int)logicalHeight-creativeImageHeight)/2;
        const logicalMouseX=mouseX/scale;
        const logicalMouseY=mouseY/scale;
        appendSolid(frame,textures.white,0,0,cast(int)logicalWidth,
            cast(int)logicalHeight,logicalWidth,logicalHeight,
            Color(0.04f,0.04f,0.04f,0.72f));

        const inventoryTab=state.creativeTab==CreativeTab.survivalInventory;
        const searchTab=state.creativeTab==CreativeTab.searchItems;
        const background=inventoryTab?textures.creativeInventoryBackground
            :(searchTab?textures.creativeSearchBackground
                :textures.creativeItemsBackground);
        // Unselected tabs sit behind the central panel. The selected tab is
        // drawn again after the panel so its open edge joins the active page.
        foreach(index;0..7)
        {
            const selected=cast(int)state.creativeTab==index;
            if(!selected)
                appendFullSprite(frame,textures.topUnselected[index],
                    creativeTabX(left,index),top-28,26,32,logicalWidth,
                    logicalHeight);
        }
        foreach(index;0..7)
        {
            if(index==5)continue; // Operator Utilities is hidden by default.
            const selected=cast(int)state.creativeTab==7+index;
            if(!selected)
                appendFullSprite(frame,textures.bottomUnselected[index],
                    creativeTabX(left,index),top+132,26,32,logicalWidth,
                    logicalHeight);
        }
        appendCreativeBackground(frame,background,left,top,logicalWidth,
            logicalHeight);
        const selectedIndex=cast(int)state.creativeTab;
        if(selectedIndex<7)
            appendFullSprite(frame,textures.topSelected[selectedIndex],
                creativeTabX(left,selectedIndex),top-28,26,32,logicalWidth,
                logicalHeight);
        else
        {
            const bottomIndex=selectedIndex-7;
            if(bottomIndex!=5) // Operator Utilities is hidden by default.
                appendFullSprite(frame,textures.bottomSelected[bottomIndex],
                    creativeTabX(left,bottomIndex),top+132,26,32,logicalWidth,
                    logicalHeight);
        }
        foreach(index;0..14)
        {
            const tab=cast(CreativeTab)index;
            const icon=creativeTabIcon(tab);
            const x=creativeTabX(left,index%7)+5;
            const y=index<7?top-20:top+140;
            if(icon!=ItemId.none)
                itemRenderer.appendItem(frame,ItemStack(icon,1),x,y,
                    logicalWidth,logicalHeight,blockTextures,font,fontTexture,
                    partialTick);
            else if(index!=12&&textures.creativeTabIcons[index]!=0)
            {
                if(textures.creativeTabCubeIcons[index])
                    appendDecorativeCube(frame,textures.creativeTabIcons[index],
                        x,y,logicalWidth,logicalHeight);
                else appendFullSprite(frame,textures.creativeTabIcons[index],
                    x,y,16,16,logicalWidth,logicalHeight);
            }
        }

        const hovered=hitCreativeSlot(viewportWidth,viewportHeight,mouseX,
            mouseY,state);
        if(hovered>=0)
        {
            int x,y;
            creativeSlotPosition(hovered,state,left,top,x,y);
            appendSlotHighlight(frame,textures.slotHighlightBack,x,y,
                logicalWidth,logicalHeight);
        }
        if(inventoryTab)
        {
            // tab_inventory.png reserves (73,6)-(104,48) for the player.
            // Keep the complete model, including its outer skin layer and
            // animated limbs, inside that 32x43 viewport.
            appendPlayerModel(frame,left+89.0f,top+27.0f,top+48.0f,19.0f,
                logicalMouseX,logicalMouseY,logicalWidth,logicalHeight,
                playerRenderer,player,playerTexture,partialTick,ageInTicks,
                slimArms);
            foreach(index;0..Inventory.slotCount)
            {
                const stack=inventory.slot(index);
                if(stack.empty())continue;
                int x,y;
                creativeInventorySlotPosition(index,left,top,x,y);
                itemRenderer.appendItem(frame,stack,x,y,logicalWidth,
                    logicalHeight,blockTextures,font,fontTexture,partialTick);
            }
        }
        else
        {
            frame.append(font.buildText(creativeTabName(state.creativeTab),
                left+8,top+6,logicalWidth,logicalHeight,
                Color(.25f,.25f,.25f,1)),fontTexture,Mat4.identity(),
                DrawLayer.overlay);
            if(searchTab)
                appendCreativeSearchText(frame,left,top,logicalWidth,
                    logicalHeight,state,font,fontTexture,textures.white);

            const items=state.visibleCreativeItems;
            const start=state.creativeScrollRow*9;
            foreach(visible;0..45)
            {
                const index=start+visible;
                if(index>=items.length)break;
                const x=left+9+(visible%9)*18;
                const y=top+18+(visible/9)*18;
                itemRenderer.appendItem(frame,ItemStack(items[index],1),x,y,
                    logicalWidth,logicalHeight,blockTextures,font,fontTexture,
                    partialTick);
            }
            foreach(column;0..Inventory.hotbarSize)
            {
                const stack=inventory.hotbar[column];
                if(stack.empty())continue;
                itemRenderer.appendItem(frame,stack,left+9+column*18,top+112,
                    logicalWidth,logicalHeight,blockTextures,font,fontTexture,
                    partialTick);
            }
            const maximum=state.maximumCreativeScrollRow;
            const scrollY=top+18+(maximum==0?0
                :state.creativeScrollRow*75/maximum);
            appendFullSprite(frame,maximum==0?textures.scrollerDisabled
                    :textures.scroller,left+175,scrollY,12,15,
                logicalWidth,logicalHeight);
        }

        if(hovered>=0)
        {
            int x,y;
            creativeSlotPosition(hovered,state,left,top,x,y);
            appendSlotHighlight(frame,textures.slotHighlightFront,x,y,
                logicalWidth,logicalHeight);
        }

        ItemStack hoveredStack;
        if(hovered>=creativeCatalogBase&&hovered<creativeTrashSlot)
        {
            const items=state.visibleCreativeItems;
            const index=hovered-creativeCatalogBase;
            if(index<items.length)hoveredStack=ItemStack(items[index],1);
        }
        else if(hovered>=0&&hovered<Inventory.slotCount)
            hoveredStack=inventory.slot(hovered);

        if(!inventory.carried.empty())
        {
            const carried=ItemStack(inventory.carried.item,
                inventory.carried.count,0);
            itemRenderer.appendItem(frame,carried,logicalMouseX-8,
                logicalMouseY-8,logicalWidth,logicalHeight,blockTextures,font,
                fontTexture,partialTick);
        }
        else if(hovered==creativeTrashSlot)
            appendLabelTooltip(frame,"Destroy Block",logicalMouseX,
                logicalMouseY,logicalWidth,logicalHeight,
                textures.tooltipBackground,textures.tooltipFrame,font,
                fontTexture);
        else if(!hoveredStack.empty())
            appendTooltip(frame,hoveredStack,logicalMouseX,logicalMouseY,
                logicalWidth,logicalHeight,textures.tooltipBackground,
                textures.tooltipFrame,font,fontTexture);
        else
        {
            const hoveredTab=creativeTabAt(viewportWidth,viewportHeight,
                mouseX,mouseY);
            if(hoveredTab>=0)
                appendLabelTooltip(frame,creativeTabName(
                    cast(CreativeTab)hoveredTab),logicalMouseX,logicalMouseY,
                    logicalWidth,logicalHeight,textures.tooltipBackground,
                    textures.tooltipFrame,font,fontTexture);
        }
        if(drawControllerCursor)
        {
            const cursorSize=(29+scale-1)/scale;
            appendFullSprite(frame,textures.controllerCursor,
                logicalMouseX-cursorSize/2,logicalMouseY-cursorSize/2,
                cursorSize,cursorSize,logicalWidth,logicalHeight);
        }
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
    static int creativeTabX(int left,int column)
    {
        // Seven 28-pixel tab columns nominally occupy 196 pixels while the
        // vanilla creative panel is 195 pixels wide. Anchor the special
        // rightmost top/bottom tabs to the panel edge so their artwork and
        // icons share the panel's actual center instead of the 196px grid.
        return column==6?left+creativeImageWidth-26:left+column*28;
    }

    static ItemId creativeTabIcon(CreativeTab tab)
    {
        final switch(tab)
        {
            case CreativeTab.buildingBlocks:return ItemId.bricks;
            case CreativeTab.coloredBlocks:return ItemId.none;
            case CreativeTab.naturalBlocks:return ItemId.grassBlock;
            case CreativeTab.functionalBlocks:return ItemId.none;
            case CreativeTab.redstoneBlocks:return ItemId.none;
            case CreativeTab.savedHotbars:return ItemId.none;
            case CreativeTab.searchItems:return ItemId.none;
            case CreativeTab.toolsAndUtilities:return ItemId.none;
            case CreativeTab.combat:return ItemId.none;
            case CreativeTab.foodAndDrinks:return ItemId.none;
            case CreativeTab.ingredients:return ItemId.none;
            case CreativeTab.spawnEggs:return ItemId.none;
            case CreativeTab.operatorUtilities:return ItemId.none;
            case CreativeTab.survivalInventory:return ItemId.none;
        }
    }

    static void creativeInventorySlotPosition(int index,int left,int top,
        out int x,out int y)
    {
        if(index<Inventory.storageSize)
        {
            x=left+9+(index%9)*18;
            y=top+54+(index/9)*18;
        }
        else
        {
            x=left+9+(index-Inventory.storageSize)*18;
            y=top+112;
        }
    }

    static void appendSlotHighlight(ref FrameMesh frame,uint texture,int x,
        int y,float width,float height)
    {
        // Vanilla's highlight sprites are 24x24 with their visible 16x16
        // overlay inset by four pixels on every side.
        appendFullSprite(frame,texture,x-4,y-4,24,24,width,height);
    }

    static void creativeSlotPosition(int hit,const InventoryMenuState state,
        int left,int top,out int x,out int y)
    {
        if(hit>=creativeCatalogBase&&hit<creativeTrashSlot)
        {
            const visible=hit-creativeCatalogBase-state.creativeScrollRow*9;
            x=left+9+(visible%9)*18;
            y=top+18+(visible/9)*18;
        }
        else if(hit==creativeTrashSlot)
        {x=left+173;y=top+112;}
        else creativeInventorySlotPosition(hit,left,top,x,y);
    }

    static void appendCreativeBackground(ref FrameMesh frame,uint texture,
        int x,int y,float width,float height)
    {
        Vertex[] output;
        const left=cast(float)x/width*2-1;
        const right=cast(float)(x+creativeImageWidth)/width*2-1;
        const top=1-cast(float)y/height*2;
        const bottom=1-cast(float)(y+creativeImageHeight)/height*2;
        const white=Color(1,1,1,1);
        appendQuad(output,Vec3(left,bottom,0),Vec3(right,bottom,0),
            Vec3(right,top,0),Vec3(left,top,0),Vec2(0,136.0f/256.0f),
            Vec2(195.0f/256.0f,136.0f/256.0f),
            Vec2(195.0f/256.0f,0),Vec2(0,0),white,white,white,white);
        frame.append(output,texture,Mat4.identity(),DrawLayer.overlay);
    }

    static void appendDecorativeCube(ref FrameMesh frame,uint texture,int x,
        int y,float width,float height)
    {
        Vertex[] output;
        Vec3 screen(float px,float py)
        {return Vec3(px/width*2-1,1-py/height*2,0);}
        const top=Color(1,1,1,1);
        const leftShade=Color(.78f,.78f,.78f,1);
        const rightShade=Color(.62f,.62f,.62f,1);
        appendQuad(output,screen(x,y+4),screen(x+8,y),screen(x+16,y+4),
            screen(x+8,y+8),Vec2(0,1),Vec2(0,0),Vec2(1,0),Vec2(1,1),
            top,top,top,top);
        appendQuad(output,screen(x,y+4),screen(x+8,y+8),screen(x+8,y+16),
            screen(x,y+12),Vec2(0,0),Vec2(1,0),Vec2(1,1),Vec2(0,1),
            leftShade,leftShade,leftShade,leftShade);
        appendQuad(output,screen(x+8,y+8),screen(x+16,y+4),
            screen(x+16,y+12),screen(x+8,y+16),Vec2(0,0),Vec2(1,0),
            Vec2(1,1),Vec2(0,1),rightShade,rightShade,rightShade,rightShade);
        frame.append(output,texture,Mat4.identity(),DrawLayer.overlay);
    }

    static void appendCreativeSearchText(ref FrameMesh frame,int left,int top,
        float width,float height,const InventoryMenuState state,
        const FontRenderer font,uint fontTexture,uint whiteTexture)
    {
        size_t start=state.searchEdit.cursor;
        if(start>state.searchInput.length)start=state.searchInput.length;
        while(start>0&&font.width(state.searchInput[start-1
                ..state.searchEdit.cursor])<=84)--start;
        size_t end=state.searchEdit.cursor;
        if(end>state.searchInput.length)end=state.searchInput.length;
        while(end<state.searchInput.length
            &&font.width(state.searchInput[start..end+1])<=84)++end;
        if(state.searchEdit.hasSelection)
        {
            const selectionStart=state.searchEdit.selectionStart>start
                ?state.searchEdit.selectionStart:start;
            const selectionEnd=state.searchEdit.selectionEnd<end
                ?state.searchEdit.selectionEnd:end;
            if(selectionStart<selectionEnd)
            {
                const x=left+82+font.width(state.searchInput[start
                    ..selectionStart]);
                const w=font.width(state.searchInput[selectionStart
                    ..selectionEnd]);
                appendSolid(frame,whiteTexture,x,top+6,w,10,width,height,
                    Color(.25f,.45f,.85f,.8f));
            }
        }
        frame.append(font.buildText(state.searchInput[start..end],left+82,
            top+6,width,height,Color(.25f,.25f,.25f,1)),fontTexture,
            Mat4.identity(),DrawLayer.overlay);
        const caret=state.searchEdit.cursor<=state.searchInput.length
            ?state.searchEdit.cursor:state.searchInput.length;
        const caretX=left+82+font.width(state.searchInput[start..caret]);
        appendSolid(frame,whiteTexture,caretX,top+5,1,10,width,height,
            Color(.2f,.2f,.2f,1));
    }

    static void appendLabelTooltip(ref FrameMesh frame,string label,int mouseX,
        int mouseY,float width,float height,uint background,uint frameTexture,
        const FontRenderer font,uint fontTexture)
    {
        const tooltipWidth=font.width(label);
        int x=mouseX+12;
        int y=mouseY-12;
        if(x+tooltipWidth+6>width)x=mouseX-12-tooltipWidth-6;
        if(y+19>height)y=cast(int)height-19;
        if(y<4)y=4;
        appendNineSlice(frame,background,x-3,y-4,tooltipWidth+6,19,9,
            width,height);
        appendNineSlice(frame,frameTexture,x-3,y-4,tooltipWidth+6,19,10,
            width,height);
        frame.append(font.buildText(label,x,y,width,height,Color(1,1,1,1)),
            fontTexture,Mat4.identity(),DrawLayer.overlay);
    }

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
        return inventoryGuiScale(width,height);
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
        // The source sprites include eight transparent pixels outside their
        // visible tooltip. Crop that padding before applying the metadata's
        // nine-slice border, otherwise short tooltips retain only a crushed
        // strip of opaque center pixels.
        enum int sourceInset=8;
        enum int sourceOuter=100-sourceInset;
        const visibleBorder=border-sourceInset;
        const targetBorder=visibleBorder<w/2?visibleBorder:w/2;
        const targetBorderY=visibleBorder<h/2?visibleBorder:h/2;
        immutable int[4] xs=[x,x+targetBorder,x+w-targetBorder,x+w];
        immutable int[4] ys=[y,y+targetBorderY,y+h-targetBorderY,y+h];
        immutable float[4] us=[sourceInset/100.0f,
            cast(float)border/100.0f,1.0f-cast(float)border/100.0f,
            sourceOuter/100.0f];
        immutable float[4] vs=[sourceInset/100.0f,
            cast(float)border/100.0f,1.0f-cast(float)border/100.0f,
            sourceOuter/100.0f];
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

private int inventoryGuiScale(uint width,uint height)
{
    int result=1;
    while(result<8&&width/(result+1)>=320&&height/(result+1)>=240)++result;
    return result;
}

unittest
{
    auto renderer=new InventoryMenuRenderer();
    scope(exit)destroy(renderer);
    // At 854x480 the auto GUI scale is two, so physical coordinates double.
    assert(renderer.hitSlot(854,480,(125+8)*2,(37+84)*2)==0);

    auto state=new InventoryMenuState();
    scope(exit)destroy(state);
    GamepadState gamepad;
    gamepad.connected=true;
    state.open();
    state.updateControllerCursor(0,0,gamepad,0,854,480);
    const initial=state.controllerCursor;
    assert(renderer.hitSlot(854,480,initial.x,initial.y)==0);
    state.updateControllerCursor(1,0,gamepad,0.1f,854,480);
    assert(state.controllerCursor.x>initial.x);
    state.selectCreativeTab(CreativeTab.searchItems);
    state.pasteSearch("PLANK");
    assert(state.visibleCreativeItems.length==12);
    foreach(item;state.visibleCreativeItems)
        assert(containsIgnoreCase(itemName(item),"plank"));
    state.selectAllSearch();
    state.typeSearch("stone"w);
    assert(state.searchInput=="stone"&&state.visibleCreativeItems.length>=2);
    foreach(item;state.visibleCreativeItems)
        assert(containsIgnoreCase(itemName(item),"stone"));
    state.selectCreativeTab(CreativeTab.naturalBlocks);
    assert(state.visibleCreativeItems.length>6);
    // The creative catalog begins at logical (left+9, top+18).
    assert(renderer.hitCreativeSlot(854,480,(116+9)*2,(52+18)*2,state)
        ==InventoryMenuRenderer.creativeCatalogBase);
}
