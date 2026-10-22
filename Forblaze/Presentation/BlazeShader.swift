/// 四辺から内側へ流れる炎。中央の余白は炎・光・火の粉で共通に保護する。
/// 出力はpremultiplied alpha。
enum BlazeShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float4 viewport; float4 animation; float4 effect; };
    struct Vertex { float4 position [[position]]; float2 uv; };
    float hash21(float2 p) {
        p=fract(p*float2(123.34,456.21));p+=dot(p,p+45.32);return fract(p.x*p.y);
    }
    float noise(float2 p) {
        float2 i=floor(p),f=fract(p);f=f*f*(3.0-2.0*f);
        return mix(mix(hash21(i),hash21(i+float2(1,0)),f.x),
                   mix(hash21(i+float2(0,1)),hash21(i+float2(1,1)),f.x),f.y);
    }
    float fbm(float2 p) {
        float value=0,amplitude=.5;
        for(int i=0;i<5;i++) {
            value+=amplitude*noise(p);
            p=float2x2(float2(1.6,1.2),float2(-1.2,1.6))*p+float2(2.7,4.3);
            amplitude*=.5;
        }
        return value;
    }
    vertex Vertex blazeVertex(uint id [[vertex_id]]) {
        float2 uv=float2((id<<1)&2,id&2);
        return {float4(uv*2-1,0,1),uv};
    }
    float4 flame(float2 p,float seed,float reach,float time) {
        float warp=fbm(float2(p.x*4+seed,p.y*2-time*.48));
        float2 q=float2(p.x*7+(warp-.5)*1.5,p.y*2.1-time*.90+seed);
        float n=fbm(q+float2(.3*fbm(q*1.8),0));
        float streak=fbm(float2(p.x*17+(warp-.5)*3,p.y*3.5-time*1.8+seed));
        float tall=fbm(float2(p.x*3.2+seed,time*.12));
        float boundary=reach*(.42+tall*.8);
        float density=boundary-p.y+(.60*n-.22)*smoothstep(0.0,.14,p.y);
        float body=smoothstep(-.026,.088,density);
        float holes=smoothstep(.16,.64,streak+(1-p.y)*.21);
        body*=mix(.56,1.0,holes);
        float hot=clamp(density*1.4+(streak-.45)*.5,0.0,1.0);
        float3 color=mix(float3(.84,.044,.003),float3(1,.10,.009),smoothstep(0.0,.23,hot));
        color=mix(color,float3(1,.42,.038),smoothstep(.16,.5,hot));
        color=mix(color,float3(1,.79,.26),smoothstep(.46,.79,hot));
        color=mix(color,float3(1,.95,.72),smoothstep(.74,1.0,hot));
        float filament=pow(max(0.0,1-abs(streak*2-1)),12.0)*smoothstep(-.035,.025,density)*(1-smoothstep(.025,.23,density));
        color+=float3(.74,.28,.035)*filament;
        float alpha=body*(.56+.36*hot)*(1-smoothstep(.78,1.02,p.y));
        return float4(min(color,float3(1))*alpha,alpha);
    }
    float edgeVisibility(float2 uv,float2 viewport) {
        float2 edge=min(uv,1-uv)*viewport/min(viewport.x,viewport.y);
        return 1-smoothstep(.16,.23,min(edge.x,edge.y));
    }
    float ignition(float2 uv,constant Uniforms &u) {
        float2 scale=u.viewport.xy/min(u.viewport.x,u.viewport.y),origin=u.viewport.zw;
        float furthest=length(max(origin,1-origin)*scale);
        float distance=length((uv-origin)*scale)/max(furthest,.001);
        return 1-smoothstep(u.effect.x*1.15-.08,u.effect.x*1.15+.02,distance);
    }
    float4 edgeFlame(float along,float depth,float seed,float voice,float time) {
        if(depth>=.23) return float4(0);
        float reach=.68+voice*.20;
        float4 back=flame(float2(along*.70+.13,depth/.23+.05),seed+19,reach+.07,time*.82+seed);
        float4 front=flame(float2(along*.92,depth/.23),seed,reach,time+seed*.37);
        return front+back*(1-front.a)*.62;
    }
    fragment float4 blazeFragment(Vertex in [[stage_in]],constant Uniforms &u [[buffer(0)]]) {
        float2 uv=in.uv;
        float visibility=edgeVisibility(uv,u.viewport.xy);
        if(u.animation.y<=0 || visibility<=0) return float4(0);
        float time=u.animation.x,voice=u.animation.w;
        float2 scale=u.viewport.xy/min(u.viewport.x,u.viewport.y);
        float4 bottom=edgeFlame(uv.x*scale.x,uv.y*scale.y,1.3,voice,time);
        float4 top=edgeFlame((1-uv.x)*scale.x,(1-uv.y)*scale.y,37.7,voice,time);
        float4 left=edgeFlame((1-uv.y)*scale.y,uv.x*scale.x,71.2,voice,time);
        float4 right=edgeFlame(uv.y*scale.y,(1-uv.x)*scale.x,113.6,voice,time);
        float4 color=bottom+top*(1-bottom.a);
        color=left+color*(1-left.a);
        color=right+color*(1-right.a);
        float2 edge=min(uv,1-uv)*scale;
        float haze=(exp(-edge.x*26)+exp(-edge.y*26))*(.09+.02*sin(time*.73));
        float hazeAlpha=haze*.4;
        color.rgb+=float3(1,.105,.017)*hazeAlpha*(1-color.a);
        color.a+=hazeAlpha*(1-color.a);
        color*=u.animation.y*ignition(uv,u)*visibility;
        color.rgb=min(color.rgb,float3(color.a));
        return color;
    }
    struct SparkVertex {float4 position [[position]];float2 uv;float2 screenUV;float alpha;};
    vertex SparkVertex sparkVertex(uint vertexID [[vertex_id]],uint id [[instance_id]],constant Uniforms &u [[buffer(0)]]) {
        const float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
        float2 corner=corners[vertexID];
        float seed=hash21(float2(id+1,4)),start=hash21(float2(id+1,13));
        float speed=.065+seed*.11,time=u.animation.x;
        float life=fract(time*speed+start),drift=hash21(float2(id+1,9))*2-1;
        float x=hash21(float2(id+1,1))+sin(time*.5+seed*20+life*4)*.026+drift*life*.045;
        float2 scale=u.viewport.xy/min(u.viewport.x,u.viewport.y);
        float depth=life*.24;
        uint edge=id%4;
        float2 center;
        if(edge==0) center=float2(x,depth/scale.y);
        else if(edge==1) center=float2(1-x,1-depth/scale.y);
        else if(edge==2) center=float2(depth/scale.x,1-x);
        else center=float2(1-depth/scale.x,x);
        float size=(.45+hash21(float2(id+1,7))*1.25)*(1.1-life*.5);
        float2 radius=(edge<2 ? float2(4,7):float2(7,4))*size*u.effect.y/u.viewport.xy;
        float2 screenUV=center+corner*radius;
        float alpha=sin(life*M_PI_F)*u.animation.z*(.3+u.animation.w*.7)*ignition(center,u);
        float2 sparkUV=edge<2 ? corner:corner.yx;
        return {float4(screenUV*2-1,0,1),sparkUV,screenUV,alpha};
    }
    fragment float4 sparkFragment(SparkVertex in [[stage_in]],constant Uniforms &u [[buffer(0)]]) {
        float glow=exp(-dot(in.uv,in.uv)*4)*.22;
        float core=exp(-in.uv.x*in.uv.x*80-in.uv.y*in.uv.y*8);
        float alpha=clamp((glow+core)*in.alpha,0.0,1.0)*edgeVisibility(in.screenUV,u.viewport.xy);
        float3 color=mix(float3(1,.32,.035),float3(1,.90,.48),core);
        return float4(color*alpha,alpha);
    }
    """
}
