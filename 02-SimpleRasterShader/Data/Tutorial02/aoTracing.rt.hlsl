/**********************************************************************************************************************
# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
# following conditions are met:
#  * Redistributions of code must retain the copyright notice, this list of conditions and the following disclaimer.
#  * Neither the name of NVIDIA CORPORATION nor the names of its contributors may be used to endorse or promote products
#    derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT
# SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA,
# OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
# ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
**********************************************************************************************************************/

// Some shared Falcor stuff for talking between CPU and GPU code
#include "HostDeviceSharedMacros.h"

// Include and import common Falcor utilities and data structures
__import Raytracing;                   // Shared ray tracing specific functions & data
__import ShaderCommon;                 // Shared shading data structures
__import Shading;                      // Shading functions, etc     

// A separate file defining the mostly mathematical utilities we use below
#include "hlslUtils.hlsli"

// Payload for our AO rays.
struct AORayPayload
{
	float aoValue;  // Store 0 if we hit a surface, 1 if we miss all surfaces
};

// A constant buffer we'll populate from our C++ code 
cbuffer RayGenCB
{
	float gAORadius;
	uint  gFrameCount;
	float gMinT;
	uint  gNumRays;
}

// Input and out textures that need to be set by the C++ code
Texture2D<float4> gPos;
Texture2D<float4> gNorm;
RWTexture2D<float4> gOutput;

// A wrapper function that encapsulates shooting an ambient occlusion ray query
float shootAmbientOcclusionRay( float3 orig, float3 dir, float minT, float maxT )
{
	AORayPayload rayPayload = { 0. };

	RayDesc rayAO = {orig, minT, dir, maxT};

	TraceRay(gRtScene,
		RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
		0xFF, 0, hitProgramCount, 0, rayAO, rayPayload);

	return rayPayload.aoValue;
}


// How do we generate the rays that we trace?
[shader("raygeneration")]
void AoRayGen()
{
	// Where is this thread's ray on screen?
	uint2 launchIndex = DispatchRaysIndex().xy;
	uint2 launchDim   = DispatchRaysDimensions().xy;

	// Initialize a random seed, per-pixel, based on a screen position and temporally varying count
	uint randSeed = initRand(launchIndex.x + launchIndex.y * launchDim.x, gFrameCount, 16);

	float4 worldPos = gPos[launchIndex];
	float4 worldNorm = gNorm[launchIndex];

	float ambientOcclusion = float(gNumRays);

	if (worldPos.w != 0.0f)
	{
		// Start accumulating from zero if we don't hit the background
		ambientOcclusion = 0.0f;

		for (int i = 0; i < gNumRays; i++)
		{

			// Sample cosine-weighted hemisphere around surface normal to pick a random ray direction
			float3 worldDir = getCosHemisphereSample(randSeed, worldNorm.xyz);

			// Shoot our ambient occlusion ray and update the value we'll output with the result
			ambientOcclusion += shootAmbientOcclusionRay(worldPos.xyz, worldDir, gMinT, gAORadius);
		}
	}

	float aoColor = ambientOcclusion / float(gNumRays);
	gOutput[launchIndex] = float4(aoColor, aoColor, aoColor, 1.0f);
}



// What code is executed when our ray misses all geometry?
[shader("miss")]
void AoMiss(inout AORayPayload rayData)
{
	// Our ambient occlusion value is 1 if we hit nothing.
	rayData.aoValue = 1.0f;
}

[shader("anyhit")]
void AoAnyHit(inout AORayPayload rayData, BuiltInTriangleIntersectionAttributes attribs)
{
	// Is this a transparent part of the surface?  If so, ignore this hit
	if (alphaTestFails(attribs))
		IgnoreHit();
}

