module chat_font_smoke;

import std.file : tempDir, mkdirRecurse, rmdirRecurse;
import std.path : buildPath;
import std.uuid : randomUUID;
import std.stdio : writeln;
import minecraftd.client.chat.chat_state;
import minecraftd.client.menu.options_menu;
import minecraftd.client.render.chat_renderer;
import minecraftd.client.render.font_renderer;
import minecraftd.client.render.unicode_font : FontGlyph;
import minecraftd.client.render.texture_manager : ImageData;
import minecraftd.client.render.mesh;

void main()
{
    const root=buildPath(tempDir(),"mcde-chat-"~randomUUID().toString());
    mkdirRecurse(root);scope(exit)rmdirRecurse(root);
    auto options=new OptionsMenuState(root);
    // Deliberately place glyphs outside the old ASCII grid coordinates.
    FontGlyph[dchar] glyphs;
    foreach(dchar c;"/help?é")glyphs[c]=FontGlyph(.75f,.5f,.765625f,.515625f,7,8);
    auto font=new FontRenderer(ImageData(128,128,new ubyte[128*128*4]),glyphs);
    auto renderer=new ChatRenderer(font,17,18);
    auto chat=new ChatState();chat.active=true;
    chat.messages=[ChatMessage("/help é",0,ChatMessageKind.normal)];
    chat.input="/help";chat.cursor=chat.input.length;
    chat.suggestions=["/help"];
    foreach(size;[[960u,540u],[1920u,1080u]])
    {
        FrameMesh frame;renderer.append(frame,size[0],size[1],chat,options);
        size_t textDraws;
        foreach(draw;frame.draws)if(draw.textureIndex==17)
        {
            ++textDraws;
            foreach(vertex;frame.vertices[draw.firstVertex..draw.firstVertex+draw.vertexCount])
            {
                assert(vertex.uv[0]>=.75f&&vertex.uv[0]<=.765625f,
                    "Chat sampled the old ASCII grid instead of the shared font atlas");
                assert(vertex.uv[1]>=.5f&&vertex.uv[1]<=.515625f);
            }
        }
        assert(textDraws==3,"History, suggestions and input must all use the shared font");
    }
    writeln("PASS: chat history, input and suggestions use packed font UVs at both window sizes");
}
