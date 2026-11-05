#include "../Sources/Solver.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
static uint32_t state;
static uint32_t rng(void){state^=state<<13;state^=state>>17;state^=state<<5;return state;}
static int fixedValue;
static void spawn(int32_t b[16]){int cells[16],n=0;for(int i=0;i<16;i++)if(!b[i])cells[n++]=i;if(n){int i=cells[rng()%n];b[i]=fixedValue?fixedValue:((rng()%10==0)?4:2);}}
int main(int argc,char **argv){int games=argc>1?atoi(argv[1]):3;int maxmoves=argc>2?atoi(argv[2]):5000;
 fixedValue=argc>3?atoi(argv[3]):0;if(fixedValue!=2&&fixedValue!=4)fixedValue=0;solver_set_spawn_value(fixedValue);
 for(int g=1;g<=games;g++){state=0xabc123u+g;int32_t b[16]={0},out[16];spawn(b);spawn(b);int step=0;long score=0;int best=0;clock_t start=clock();
  while(step<maxmoves){int d=solver_best(b);if(d<0)break;if(!solver_move(b,d,out)){fprintf(stderr,"illegal move\n");return 1;}
   int bc[32]={0},ac[32]={0};for(int i=0;i<16;i++){for(int v=b[i],r=0;v>1;v>>=1)r++,bc[r]++;for(int v=out[i],r=0;v>1;v>>=1)r++,ac[r]++;} /* merges add the new tile's value */
   for(int r=1;r<31;r++) if(ac[r+1]>bc[r+1]) score+=(long)(ac[r+1]-bc[r+1])<<(r+1);
   for(int i=0;i<16;i++) b[i]=out[i];
   spawn(b);step++;
   if(step%500==0){int m2=0;for(int i=0;i<16;i++)if(b[i]>m2)m2=b[i];printf("  progress moves=%d score=%ld board",step,score);
    for(int i=0;i<16;i++)printf("%s%d",i?",":"",b[i]);printf("\n");fflush(stdout);}
   /* 実機の実行ログと同じ形: 2048 以上のタイルが増えた時点を残す */
   {int m=0;for(int i=0;i<16;i++)if(b[i]>m)m=b[i];
    if(m>best){best=m;if(m>=2048&&!(m&(m-1)))printf("  milestone tile=%d score=%ld moves=%d\n",m,score,step);fflush(stdout);}}}
  int max=0;for(int i=0;i<16;i++)if(b[i]>max)max=b[i];printf("seed %d max=%d score=%ld moves=%d cpu=%.2fs%s\n",g,max,score,step,(double)(clock()-start)/CLOCKS_PER_SEC,step==maxmoves?" capped":"");fflush(stdout);
 }
}
