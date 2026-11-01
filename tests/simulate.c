#include "../Sources/Solver.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
static uint32_t state;
static uint32_t rng(void){state^=state<<13;state^=state>>17;state^=state<<5;return state;}
static void spawn(int32_t b[16]){int cells[16],n=0;for(int i=0;i<16;i++)if(!b[i])cells[n++]=i;if(n){int i=cells[rng()%n];b[i]=(rng()%10==0)?4:2;}}
int main(int argc,char **argv){int games=argc>1?atoi(argv[1]):3;int maxmoves=argc>2?atoi(argv[2]):5000;
 for(int g=1;g<=games;g++){state=0xabc123u+g;int32_t b[16]={0},out[16];spawn(b);spawn(b);int step=0;clock_t start=clock();
  while(step<maxmoves){int d=solver_best(b);if(d<0)break;if(!solver_move(b,d,out)){fprintf(stderr,"illegal move\n");return 1;}for(int i=0;i<16;i++)b[i]=out[i];spawn(b);step++;}
  int max=0;for(int i=0;i<16;i++)if(b[i]>max)max=b[i];printf("seed %d max=%d moves=%d cpu=%.2fs%s\n",g,max,step,(double)(clock()-start)/CLOCKS_PER_SEC,step==maxmoves?" capped":"");fflush(stdout);
 }
}
