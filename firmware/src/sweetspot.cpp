// Feature specification: ml/compare_models.py:audio_features (initial 512 samples).
#include "sweetspot.h"
#include "distance_model.h"
#include "distance_selftest.h"
#include <math.h>

static_assert(SS_N_FEATURES == DISTANCE_MODEL_FEATURES, "feature count");
static_assert(SS_CLIP_SAMPLES == 512, "ridge input must be 32 ms");
namespace {
constexpr double PI = 3.14159265358979323846;
// Static workspace: only the microphone task calls inference. Avoid its 6 KB stack.
double x[512], re[512], im[512], power[256], halfPower[128];
double window512[512], window256[256], dct[16][64], full[64], half[32], env[32];
bool initialized = false;
void initialize() {
  if (initialized) return;
  for (int i=0;i<512;i++) window512[i]=.5-.5*cos(2*PI*i/511);
  for (int i=0;i<256;i++) window256[i]=.5-.5*cos(2*PI*i/255);
  for (int k=1;k<=16;k++) for (int i=0;i<64;i++)
    dct[k-1][i]=sqrt(2.0/64)*cos(PI*k*(2*i+1)/128);
  initialized=true;
}
void spectrum(const double *input,int n,int bands,double *out,double *p) {
  const double *window=n==512?window512:window256;
  for(int i=0;i<n;i++){re[i]=input[i]*window[i];im[i]=0;}
  for(int i=1,j=0;i<n;i++){
    int bit=n>>1;for(;j&bit;bit>>=1)j^=bit;j^=bit;
    if(i<j){double t=re[i];re[i]=re[j];re[j]=t;t=im[i];im[i]=im[j];im[j]=t;}
  }
  for(int length=2;length<=n;length<<=1){
    double wr=cos(-2*PI/length),wi=sin(-2*PI/length);
    for(int start=0;start<n;start+=length){
      double ur=1,ui=0;
      for(int j=0;j<length/2;j++){
        int a=start+j,b=a+length/2;
        double vr=re[b]*ur-im[b]*ui,vi=re[b]*ui+im[b]*ur;
        re[b]=re[a]-vr;im[b]=im[a]-vi;re[a]+=vr;im[a]+=vi;
        double next=ur*wr-ui*wi;ui=ur*wi+ui*wr;ur=next;
      }
    }
  }
  double sum=0;
  for(int i=1;i<=n/2;i++){p[i-1]=re[i]*re[i]+im[i]*im[i];sum+=p[i-1];}
  if(sum<1e-20)sum=1e-20;
  for(int i=0;i<n/2;i++)p[i]/=sum;
  int width=n/2/bands;
  for(int b=0;b<bands;b++){
    double energy=0;for(int i=b*width;i<(b+1)*width;i++)energy+=p[i];
    out[b]=log10(energy+1e-8);
  }
}
}

void ss_features(const int16_t *clip,float *out){
  initialize();double mean=0,sumsq=0;int clipped=0;
  for(int i=0;i<512;i++){mean+=clip[i];if(clip[i]>=30000||clip[i]<=-30000)clipped++;}
  mean/=512;
  for(int i=0;i<512;i++){x[i]=clip[i]-mean;sumsq+=x[i]*x[i];}
  double rms=sqrt(sumsq/512),scale=rms>1?rms:1;
  for(int i=0;i<512;i++)x[i]/=scale;
  spectrum(x,512,64,full,power);spectrum(x+256,256,32,half,halfPower);
  for(int i=0;i<64;i++)out[i]=full[i];
  for(int i=0;i<32;i++)out[64+i]=half[i];
  for(int k=0;k<16;k++){double v=0;for(int i=0;i<64;i++)v+=dct[k][i]*full[i];out[96+k]=v;}
  double centroid=0,concentration=0,bandwidth=0;
  for(int i=0;i<256;i++){centroid+=(i+1)/256.0*power[i];concentration+=power[i]*power[i];}
  for(int i=0;i<256;i++){double d=(i+1)/256.0-centroid;bandwidth+=d*d*power[i];}
  out[112]=centroid;out[113]=sqrt(bandwidth);
  const double levels[]={.5,.85,.95};
  for(int k=0;k<3;k++){
    double cumulative=0;int index=255;
    for(int i=0;i<256;i++){cumulative+=power[i];if(cumulative>=levels[k]){index=i;break;}}
    out[114+k]=(index+1)/256.0;
  }
  double variation=0,fourth=0,lag1=0,lag16=0;
  for(int i=0;i<512;i++){
    double squared=x[i]*x[i];fourth+=squared*squared;
    if(i>0){variation+=fabs(x[i]-x[i-1]);lag1+=x[i]*x[i-1];}
    if(i>=16)lag16+=x[i]*x[i-16];
  }
  out[117]=concentration;out[118]=variation/511;out[119]=fourth/512;
  out[120]=clipped/512.0;out[121]=log10(rms+1);
  double envsum=0;
  for(int b=0;b<32;b++){
    double energy=0;for(int j=0;j<16;j++)energy+=x[b*16+j]*x[b*16+j];
    env[b]=sqrt(energy/16);envsum+=env[b];
  }
  if(envsum<1e-12)envsum=1e-12;
  for(int b=0;b<32;b++)out[122+b]=log10(env[b]/envsum+1e-8);
  out[154]=lag1/511;out[155]=lag16/496;
}

SweetSpotResult ss_infer_features(const float *features){
  double value=DISTANCE_BIAS;
  for(int i=0;i<SS_N_FEATURES;i++)value+=(double)features[i]*DISTANCE_COEFF[i];
  if(!isfinite(value))value=12;
  if(value<0)value=0;
  SweetSpotResult r;
  r.distance_cm=value;r.sweet=value<=4;
  double pct=value/12*100;if(pct>100)pct=100;
  r.off_pct=r.sweet?0:(uint8_t)(pct+.5);
  // There is no calibrated probability for this regressor; do not invent one.
  r.confidence=0;r.p_sweet=NAN;
  return r;
}
SweetSpotResult ss_classify(const int16_t *clip){
  static float features[SS_N_FEATURES];
  ss_features(clip,features);return ss_infer_features(features);
}

bool ss_self_test(){
  for(int i=0;i<SS_SELFTEST_COUNT;i++){
    SweetSpotResult r=ss_classify(SS_SELFTEST_CLIPS[i]);
    if(!isfinite(r.distance_cm)||fabs(r.distance_cm-SS_SELFTEST_DISTANCE[i])>0.005
        ||r.sweet!=(SS_SELFTEST_DISTANCE[i]<=4))return false;
  }
  return true;
}
