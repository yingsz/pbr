Shader "PBR"
{
    Properties
    {
        _Color("Color", Color) = (1,1,1,1)
        _MainTex("Albedo", 2D) = "white" {}

        _Cutoff("Alpha Cutoff", Range(0.0, 1.0)) = 0.5

        _Glossiness("Smoothness", Range(0.0, 1.0)) = 0.5
        _GlossMapScale("Smoothness Scale", Range(0.0, 1.0)) = 1.0
        [Enum(Metallic Alpha,0,Albedo Alpha,1)] _SmoothnessTextureChannel ("Smoothness texture channel", Float) = 0

        [Gamma] _Metallic("Metallic", Range(0.0, 1.0)) = 0.0
        _MetallicGlossMap("Metallic", 2D) = "white" {}

        [ToggleOff] _SpecularHighlights("Specular Highlights", Float) = 1.0
        [ToggleOff] _GlossyReflections("Glossy Reflections", Float) = 1.0

        _BumpScale("Scale", Float) = 1.0
        _BumpMap("Normal Map", 2D) = "bump" {}

        _Parallax ("Height Scale", Range (0.005, 0.08)) = 0.02
        _ParallaxMap ("Height Map", 2D) = "black" {}

        _OcclusionStrength("Strength", Range(0.0, 1.0)) = 1.0
        _OcclusionMap("Occlusion", 2D) = "white" {}

        _EmissionColor("Color", Color) = (0,0,0)
        _EmissionMap("Emission", 2D) = "white" {}

        _DetailMask("Detail Mask", 2D) = "white" {}

        _DetailAlbedoMap("Detail Albedo x2", 2D) = "grey" {}
        _DetailNormalMapScale("Scale", Float) = 1.0
        _DetailNormalMap("Normal Map", 2D) = "bump" {}

        [Enum(UV0,0,UV1,1)] _UVSec ("UV Set for secondary textures", Float) = 0


        // Blending state
        [HideInInspector] _Mode ("__mode", Float) = 0.0
        [HideInInspector] _SrcBlend ("__src", Float) = 1.0
        [HideInInspector] _DstBlend ("__dst", Float) = 0.0
        [HideInInspector] _ZWrite ("__zw", Float) = 1.0
    }

     SubShader
    {
        Tags { "RenderType"="Opaque" "PerformanceChecks"="False" }
        LOD 300

        pass{
            
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "UnityCG.cginc"
            #include "AutoLight.cginc"
            #include "UnityStandardInput.cginc"

             

            struct vertinput
            {
                float4 vertex   : POSITION;
                half3 normal    : NORMAL;
                float2 uv0      : TEXCOORD0;
                float2 uv1      : TEXCOORD1;
                #if defined(DYNAMICLIGHTMAP_ON) || defined(UNITY_PASS_META)
                    float2 uv2      : TEXCOORD2;
                #endif
                #ifdef _TANGENT_TO_WORLD
                    half4 tangent   : TANGENT;
                #endif
            };

            struct v2f
            {
                UNITY_POSITION(pos);
                float4 tex                            : TEXCOORD0;
                float3 eyeVec                         : TEXCOORD1;
                float4 tangentToWorldAndPackedData[3] : TEXCOORD2;    // [3x3:tangentToWorld | 1x3:viewDirForParallax or worldPos]
                half4 ambientOrLightmapUV             : TEXCOORD5;    // SH or Lightmap UV
                UNITY_SHADOW_COORDS(6)
                UNITY_FOG_COORDS(7)

                // next ones would not fit into SM2.0 limits, but they are always for SM3.0+
                #if UNITY_REQUIRE_FRAG_WORLDPOS && !UNITY_PACK_WORLDPOS_WITH_TANGENT
                    float3 posWorld                 : TEXCOORD8;
                #endif
            };

            inline half4 VertexGIForward(vertinput v, float3 posWorld, half3 normalWorld)
            {
                half4 ambientOrLightmapUV = 0;
                // Static lightmaps
                #ifdef LIGHTMAP_ON
                    ambientOrLightmapUV.xy = v.uv1.xy * unity_LightmapST.xy + unity_LightmapST.zw;
                    ambientOrLightmapUV.zw = 0;
                // Sample light probe for Dynamic objects only (no static or dynamic lightmaps)
                #elif UNITY_SHOULD_SAMPLE_SH
                    #ifdef VERTEXLIGHT_ON
                        // Approximated illumination from non-important point lights
                        ambientOrLightmapUV.rgb = Shade4PointLights (
                            unity_4LightPosX0, unity_4LightPosY0, unity_4LightPosZ0,
                            unity_LightColor[0].rgb, unity_LightColor[1].rgb, unity_LightColor[2].rgb, unity_LightColor[3].rgb,
                            unity_4LightAtten0, posWorld, normalWorld);
                    #endif

                    ambientOrLightmapUV.rgb = ShadeSHPerVertex (normalWorld, ambientOrLightmapUV.rgb);
                #endif

                #ifdef DYNAMICLIGHTMAP_ON
                    ambientOrLightmapUV.zw = v.uv2.xy * unity_DynamicLightmapST.xy + unity_DynamicLightmapST.zw;
                #endif

                return ambientOrLightmapUV;
            }

            struct FragmentCommonData
            {
                half3 diffColor, specColor;
                // Note: smoothness & oneMinusReflectivity for optimization purposes, mostly for DX9 SM2.0 level.
                // Most of the math is being done on these (1-x) values, and that saves a few precious ALU slots.
                half oneMinusReflectivity, smoothness;
                float3 normalWorld;
                float3 eyeVec;
                half alpha;
                float3 posWorld;
            };

            inline FragmentCommonData MetallicSetup (float4 i_tex)
            {
                half2 metallicGloss = MetallicGloss(i_tex.xy);
                half metallic = metallicGloss.x;
                half smoothness = metallicGloss.y; // this is 1 minus the square root of real roughness m.

                half oneMinusReflectivity;
                half3 specColor;
                half3 diffColor = DiffuseAndSpecularFromMetallic (Albedo(i_tex), metallic, /*out*/ specColor, /*out*/ oneMinusReflectivity);

                FragmentCommonData o = (FragmentCommonData)0;
                o.diffColor = diffColor;
                o.specColor = specColor;
                o.oneMinusReflectivity = oneMinusReflectivity;
                o.smoothness = smoothness;
                return o;
            }

            UnityLight MainLight ()
            {
                UnityLight l;

                l.color = _LightColor0.rgb;
                l.dir = _WorldSpaceLightPos0.xyz;
                return l;
            }

            half3 NormalInTangentSpace(float4 texcoords)
            {
                half3 normalTangent = UnpackScaleNormal(tex2D (_BumpMap, texcoords.xy), _BumpScale);
                return normalTangent;
            }

            float3 PerPixelWorldNormal(float4 i_tex, float4 tangentToWorld[3])
            {
                half3 tangent = tangentToWorld[0].xyz;
                half3 binormal = tangentToWorld[1].xyz;
                half3 normal = tangentToWorld[2].xyz;
                half3 normalTangent = NormalInTangentSpace(i_tex);
                float3 normalWorld = normalize(tangent * normalTangent.x + binormal * normalTangent.y + normal * normalTangent.z); // @TODO: see if we can squeeze this normalize on SM2.0 as well
                return normalWorld;
            }

            inline FragmentCommonData FragmentSetup (inout float4 i_tex, float3 i_eyeVec, half3 i_viewDirForParallax, float4 tangentToWorld[3], float3 i_posWorld)
            {
                i_tex = Parallax(i_tex, i_viewDirForParallax);

                half alpha = Alpha(i_tex.xy);
                #if defined(_ALPHATEST_ON)
                    clip (alpha - _Cutoff);
                #endif

                FragmentCommonData o = MetallicSetup (i_tex);
                o.normalWorld = PerPixelWorldNormal(i_tex, tangentToWorld);
                o.eyeVec = normalize(i_eyeVec);
                o.posWorld = i_posWorld;

                // NOTE: shader relies on pre-multiply alpha-blend (_SrcBlend = One, _DstBlend = OneMinusSrcAlpha)
                o.diffColor = PreMultiplyAlpha (o.diffColor, alpha, o.oneMinusReflectivity, /*out*/ o.alpha);
                return o;
            }

            #ifdef _PARALLAXMAP
                #define IN_VIEWDIR4PARALLAX(i) NormalizePerPixelNormal(half3(i.tangentToWorldAndPackedData[0].w,i.tangentToWorldAndPackedData[1].w,i.tangentToWorldAndPackedData[2].w))
                #define IN_VIEWDIR4PARALLAX_FWDADD(i) NormalizePerPixelNormal(i.viewDirForParallax.xyz)
            #else
                #define IN_VIEWDIR4PARALLAX(i) half3(0,0,0)
                #define IN_VIEWDIR4PARALLAX_FWDADD(i) half3(0,0,0)
            #endif

            #if UNITY_REQUIRE_FRAG_WORLDPOS
                #if UNITY_PACK_WORLDPOS_WITH_TANGENT
                    #define IN_WORLDPOS(i) half3(i.tangentToWorldAndPackedData[0].w,i.tangentToWorldAndPackedData[1].w,i.tangentToWorldAndPackedData[2].w)
                #else
                    #define IN_WORLDPOS(i) i.posWorld
                #endif
                #define IN_WORLDPOS_FWDADD(i) i.posWorld
            #else
                #define IN_WORLDPOS(i) half3(0,0,0)
                #define IN_WORLDPOS_FWDADD(i) half3(0,0,0)
            #endif
            #define FRAGMENT_SETUP(x) FragmentCommonData x = \
                FragmentSetup(i.tex, i.eyeVec, IN_VIEWDIR4PARALLAX(i), i.tangentToWorldAndPackedData, IN_WORLDPOS(i));


            inline UnityGI FragmentGI (FragmentCommonData s, half occlusion, half4 i_ambientOrLightmapUV, half atten, UnityLight light, bool reflections)
            {
                UnityGIInput d;
                d.light = light;
                d.worldPos = s.posWorld;
                d.worldViewDir = -s.eyeVec;
                d.atten = atten;
                #if defined(LIGHTMAP_ON) || defined(DYNAMICLIGHTMAP_ON)
                    d.ambient = 0;
                    d.lightmapUV = i_ambientOrLightmapUV;
                #else
                    d.ambient = i_ambientOrLightmapUV.rgb;
                    d.lightmapUV = 0;
                #endif

                d.probeHDR[0] = unity_SpecCube0_HDR;
                d.probeHDR[1] = unity_SpecCube1_HDR;
                #if defined(UNITY_SPECCUBE_BLENDING) || defined(UNITY_SPECCUBE_BOX_PROJECTION)
                d.boxMin[0] = unity_SpecCube0_BoxMin; // .w holds lerp value for blending
                #endif
                #ifdef UNITY_SPECCUBE_BOX_PROJECTION
                d.boxMax[0] = unity_SpecCube0_BoxMax;
                d.probePosition[0] = unity_SpecCube0_ProbePosition;
                d.boxMax[1] = unity_SpecCube1_BoxMax;
                d.boxMin[1] = unity_SpecCube1_BoxMin;
                d.probePosition[1] = unity_SpecCube1_ProbePosition;
                #endif

                if(reflections)
                {
                    Unity_GlossyEnvironmentData g = UnityGlossyEnvironmentSetup(s.smoothness, -s.eyeVec, s.normalWorld, s.specColor);
                    // Replace the reflUVW if it has been compute in Vertex shader. Note: the compiler will optimize the calcul in UnityGlossyEnvironmentSetup itself
                    #if UNITY_STANDARD_SIMPLE
                        g.reflUVW = s.reflUVW;
                    #endif

                    return UnityGlobalIllumination (d, occlusion, s.normalWorld, g);
                }
                else
                {
                    return UnityGlobalIllumination (d, occlusion, s.normalWorld);
                }
            }

            inline UnityGI FragmentGI (FragmentCommonData s, half occlusion, half4 i_ambientOrLightmapUV, half atten, UnityLight light)
            {
                return FragmentGI(s, occlusion, i_ambientOrLightmapUV, atten, light, true);
            }

            v2f vert (vertinput v)
            {
                 v2f o;
                float4 posWorld = mul(unity_ObjectToWorld, v.vertex);
                o.tangentToWorldAndPackedData[0].w = posWorld.x;
                o.tangentToWorldAndPackedData[1].w = posWorld.y;
                o.tangentToWorldAndPackedData[2].w = posWorld.z;
                o.pos = UnityObjectToClipPos(v.vertex);
                o.tex.xy = TRANSFORM_TEX(v.uv0, _MainTex);
                o.eyeVec = posWorld.xyz - _WorldSpaceCameraPos;
                float3 normalWorld = UnityObjectToWorldNormal(v.normal);
                float4 tangentWorld = float4(UnityObjectToWorldDir(v.tangent.xyz), v.tangent.w);
                float3x3 tangentToWorld = CreateTangentToWorldPerVertex(normalWorld, tangentWorld.xyz, tangentWorld.w);
                o.tangentToWorldAndPackedData[0].xyz = tangentToWorld[0];
                o.tangentToWorldAndPackedData[1].xyz = tangentToWorld[1];
                o.tangentToWorldAndPackedData[2].xyz = tangentToWorld[2];
                //We need this for shadow receving
                UNITY_TRANSFER_SHADOW(o, v.uv1);
                o.ambientOrLightmapUV = VertexGIForward(v, posWorld, normalWorld);
                UNITY_TRANSFER_FOG(o,o.pos);
                return o;
            }
            
            half4 frag ( v2f i):SV_Target
            {
                UNITY_APPLY_DITHER_CROSSFADE(i.pos.xy);

                FRAGMENT_SETUP(s)

                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                UnityLight mainLight = MainLight ();
                UNITY_LIGHT_ATTENUATION(atten, i, s.posWorld);

                half occlusion = Occlusion(i.tex.xy);
                UnityGI gi = FragmentGI (s, occlusion, i.ambientOrLightmapUV, atten, mainLight);

                half4 c = UNITY_BRDF_PBS (s.diffColor, s.specColor, s.oneMinusReflectivity, s.smoothness, s.normalWorld, -s.eyeVec, gi.light, gi.indirect);
                c.rgb += Emission(i.tex.xy);

                UNITY_APPLY_FOG(i.fogCoord, c.rgb);
                c.a = 1.0;
                return c;
            }
            ENDCG
        }
    }

}