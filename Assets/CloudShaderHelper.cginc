#include "UnityCG.cginc"
#define MAX_SAMPLE_COUNT 96
#define CHEAP_SAMPLE_STEP_SIZE (THICKNESS * 6 / MAX_SAMPLE_COUNT)
#define DETAIL_SAMPLE_STEP_SIZE (CHEAP_SAMPLE_STEP_SIZE / 3)

#define THICKNESS 6500
#define CENTER 4750
sampler3D _VolumeTex;
sampler3D _DetailTex;
sampler2D _HeightSignal;
sampler2D _CoverageTex;
float4 _CoverageTex_ST;
sampler2D _DetailNoiseTex;
float _CloudSize;
float _DetailTile;
float _Transcluency;
float _DetailMask;
float _CloudDentisy;
float _BeerLaw;
half4 _WindDirection;
float _SilverIntensity;
float _SilverSpread;

float LowresSample(float3 worldPos, int lod);
float FullSample(float3 worldPos, int lod);

float Remap(float original_value, float original_min, float original_max, float new_min, float new_max)
{
	return new_min + (((original_value - original_min) / (original_max - original_min)) * (new_max - new_min));
}

float RemapClamped(float original_value, float original_min, float original_max, float new_min, float new_max)
{
	return new_min + (saturate((original_value - original_min) / (original_max - original_min)) * (new_max - new_min));
}

float HenryGreenstein(float g, float cosTheta) {
	float pif = 1.0;// (1.0 / (4.0 * 3.1415926f));
	float numerator = 1 - g * g ;
	float denominator = pow(1 + g * g - 2 * g * cosTheta, 1.5);
	return pif * numerator / denominator;
}

float BeerLaw(float d, float cosTheta) {
	d *= _BeerLaw;
	float firstIntes = exp(-d);
	float secondIntens = exp(-d * 0.25) * 0.7;
	float secondIntensCurve = 0.5;
	float tmp = max(firstIntes, secondIntens * RemapClamped(cosTheta, 0.7, 1.0, secondIntensCurve, secondIntensCurve * 0.7));
	return tmp;
}

float Inscatter(float3 worldPos,float dl) {
	float heightPercent = saturate((worldPos.y - CENTER + THICKNESS / 2) / THICKNESS);
	float lodded_density = saturate(FullSample(worldPos, 1));
	float depth_probability = 0.05 + pow(saturate(lodded_density), RemapClamped(heightPercent, 0.3, 0.85, 0.5, 2.0));
	depth_probability = lerp(depth_probability, 1.0, saturate((1-dl) / 10));		//I think the original one in ppt is wrong.(or they use dl as "brigtness" rather than "occlusion"
	float vertical_probability = pow(max(0, Remap(heightPercent, 0.07, 0.14, 0.1, 1.0)), 0.8);
	return saturate(depth_probability * vertical_probability);
}

float Energy(float3 worldPos, float d, float cosTheta) {
	float hgImproved = max(HenryGreenstein(0.05, cosTheta), _SilverIntensity * HenryGreenstein(0.99 - _SilverSpread, cosTheta));
	return Inscatter(worldPos, d) * hgImproved * BeerLaw(d, cosTheta);
}

float LowresSample(float3 worldPos,int lod) {

	float heightPercent = saturate((worldPos.y - CENTER + THICKNESS / 2) / THICKNESS);
	fixed4 tempResult;
	half3 uvw = worldPos;
	uvw.xz += _WindDirection.xy * _WindDirection.z * _Time.y;
	uvw = uvw / _CloudSize;
	tempResult = tex3Dlod(_VolumeTex, half4(uvw, lod)).rgba;
	float low_freq_fBm = (tempResult.g * 0.625) + (tempResult.b * 0.25) + (tempResult.a * 0.125);

	// define the base cloud shape by dilating it with the low frequency fBm made of Worley noise.
	float sampleResult = Remap(tempResult.r, -(1.0 - low_freq_fBm), 1.0, 0.0, 1.0);

	//If you don't want to bother a coverage tex, use this.

	float heightSample = tex2Dlod(_HeightSignal, half4(0, heightPercent, 0, 0)).a;
	sampleResult *= heightSample;

	half4 coverageSampleUV = half4(TRANSFORM_TEX((worldPos.xz / _CloudSize), _CoverageTex), 0, 0);
	float coverage = tex2Dlod(_CoverageTex, coverageSampleUV).r;
	//Anvil style.
	//coverage = pow(coverage, RemapClamped(heightPercent, 0.7, 0.8, 1.0, lerp(1.0, 0.5, 0.5)));

	//This doesn't work at all! 
	//sampleResult = RemapClamped(sampleResult, coverage, 1.0, 0.0, 1.0);
	
	//Just use the old fashion way.
	sampleResult *= coverage;

	sampleResult = saturate(sampleResult);
	return sampleResult;
}

float DetailErode(float3 worldPos, float lowresSample, int lod) {
	//return lowresSample;
	float3 tempResult;
	half3 uvw = worldPos / (_DetailTile * _CloudSize);
	//tex2Dlod(_DetailNoiseTex, half4(uvw.x, 0));
	tempResult = tex3Dlod(_DetailTex, half4(uvw, lod)).rgb;
	// build High frequency Worley noise fBm
	float sampleResult = (tempResult.r * 0.625) + (tempResult.g * 0.25) + (tempResult.b * 0.125);

	float heightPercent = saturate((worldPos.y - CENTER + THICKNESS / 2) / THICKNESS);
	float high_freq_noise_modifier = lerp(sampleResult, 1.0 - sampleResult, saturate(heightPercent * 10.0));

	return Remap(lowresSample, high_freq_noise_modifier * 0.2, 1.0, 0.0, 1.0);
}

float FullSample(float3 worldPos, int lod) {
	float sampleResult = LowresSample(worldPos, lod);
	sampleResult = DetailErode(worldPos, sampleResult, lod);
	return max(sampleResult,0);
}

half rand(half3 co)
{
	return frac(sin(dot(co.xyz, half3(12.9898, 78.233, 45.5432))) * 43758.5453) - 0.5f;
}

float SampleEnergy(float3 worldPos, float3 viewDir) {
	//return 0.001;
#define DETAIL_ENERGY_SAMPLE_COUNT 6
	float totalSample = 0;
	//return 0.001;
	for (float i = 1; i <= DETAIL_ENERGY_SAMPLE_COUNT; i++) {
		half3 rand3 = half3(rand(half3(0, i, 0)), rand(half3(1, i, 0)), rand(half3(0, i, 1)));
		half3 direction = _WorldSpaceLightPos0 * 2 + normalize(rand3);
		direction = normalize(direction);
		float3 samplePoint = worldPos 
			+ (direction * i / DETAIL_ENERGY_SAMPLE_COUNT) * _Transcluency;
		totalSample += FullSample(samplePoint, 0);
	}
	float energy = Energy(worldPos ,totalSample / DETAIL_ENERGY_SAMPLE_COUNT, dot(viewDir, _WorldSpaceLightPos0));
	return energy;
}

float GetDentisy(float3 startPos, float3 dir,float maxSampleDistance, float raymarchOffset, out float intensity,out float depth) {
	float alpha = 0;
	intensity = 0;
	float raymarchDistance = raymarchOffset * (DETAIL_SAMPLE_STEP_SIZE + CHEAP_SAMPLE_STEP_SIZE);
	float sampleStep = CHEAP_SAMPLE_STEP_SIZE;
	bool detailedSample = false;
	int missedStepCount = 0;
	[loop]
	for (int j = 0; j < MAX_SAMPLE_COUNT; j++) {
		float3 rayPos = startPos + dir * raymarchDistance;
		float sampleResult = LowresSample(rayPos,0);
		if (!detailedSample) {
			if (sampleResult > 0) {
				detailedSample = true;
				raymarchDistance -= sampleStep;
				sampleStep = DETAIL_SAMPLE_STEP_SIZE;
				missedStepCount = 0;
				continue;
			}
		}
		else {
			if (sampleResult <= 0) {
				missedStepCount++;
				if (missedStepCount > 4) {
					detailedSample = false;
					sampleStep = CHEAP_SAMPLE_STEP_SIZE;
					continue;
				}
			}
			sampleResult = DetailErode(rayPos, sampleResult, 0);
			if (sampleResult > 0) {
				float sampledAlpha = sampleResult * DETAIL_SAMPLE_STEP_SIZE * _CloudDentisy;	//�����alphaֵ
				float sampledEnergy;				//������rayPos��eyePos�ķ����ʡ�
				sampledEnergy = SampleEnergy(rayPos, dir);
				intensity += (1 - alpha) * sampledEnergy * sampledAlpha;
				if (alpha < 0.5 && alpha + (1 - alpha) * sampledAlpha >= 0.5) {
					//record depth.
					depth = raymarchDistance;
				}
				alpha += (1 - alpha) * sampledAlpha;
				if (alpha > 1) {
					intensity;
					return 1;
				}
			}
		}
		raymarchDistance += sampleStep;
		if (raymarchDistance > maxSampleDistance)
			break;
	}
	return alpha;
}
