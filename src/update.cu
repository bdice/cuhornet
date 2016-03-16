#include <thrust/device_vector.h>
#include <thrust/host_vector.h>

#include "main.h"
#include "update.hpp"


using namespace std;

// No duplicates allowed
__global__ void deviceUpdatesSweep1(cuStinger* custing, BatchUpdate* bu,int32_t updatesPerBlock)
{
	int32_t* d_utilized      = custing->getDeviceUtilized();
	int32_t* d_max           = custing->getDeviceMax();
	int32_t** d_adj          = custing->getDeviceAdj();	
	int32_t* d_updatesSrc    = bu->getDeviceSrc();
	int32_t* d_updatesDst    = bu->getDeviceDst();
	int32_t batchSize        = bu->getDeviceBatchSize();
	int32_t* d_incCount      = bu->getDeviceIncCount();
	int32_t* d_indIncomplete = bu->getDeviceIndIncomplete();
	int32_t* d_indDuplicate  = bu->getDeviceIndDuplicate();
	int32_t* d_dupCount      = bu->getDeviceDuplicateCount();
	int32_t* d_dupRelPos     = bu->getDeviceDupRelPos();


	int32_t init_pos = blockIdx.x * updatesPerBlock;

	for (int32_t i=0; i<updatesPerBlock; i++){
		int32_t pos=init_pos+i;
		if(pos>=batchSize)
			break;
		int32_t src = d_updatesSrc[pos];
		int32_t dst = d_updatesDst[pos];

		int32_t srcInitSize = d_utilized[src];
		int32_t found=0;
		for (int32_t e=0; e<srcInitSize; e+=blockDim.x){
			if(d_adj[src][e]==dst)
				found=1;
		}
		if(!found && threadIdx.x==0){
			int32_t ret =  atomicAdd(d_utilized+src, 1);
			if(ret<d_max[src]){
				int32_t dupInBatch=0;
				for(int32_t k=srcInitSize; k<ret; k++){
					if (d_adj[src][k]==dst)
						dupInBatch=1;
				}
				if(!dupInBatch){
					d_adj[src][ret] = dst;
				}
				else{
					int32_t duplicateID =  atomicAdd(d_dupCount, 1);
					d_indDuplicate[duplicateID] = pos;
					d_dupRelPos[duplicateID] = ret;
				}
			}
			else{
				atomicSub(d_utilized+src,1);
				// Out of space for this adjacency.
				int32_t inCompleteEdgeID =  atomicAdd(d_incCount, 1);
				d_indIncomplete[inCompleteEdgeID] = pos;
			}
		}
	}
}

__global__ void deviceUpdatesSweep2(cuStinger* custing, BatchUpdate* bu,int32_t updatesPerBlock)
{
	int32_t* d_utilized      = custing->getDeviceUtilized();
	int32_t* d_max           = custing->getDeviceMax();
	int32_t** d_adj          = custing->getDeviceAdj();	
	int32_t* d_updatesSrc    = bu->getDeviceSrc();
	int32_t* d_updatesDst    = bu->getDeviceDst();
	int32_t batchSize        = bu->getDeviceBatchSize();
	int32_t* d_incCount      = bu->getDeviceIncCount();
	int32_t* d_indIncomplete = bu->getDeviceIndIncomplete();
	int32_t* d_indDuplicate  = bu->getDeviceIndDuplicate();
	int32_t* d_dupCount      = bu->getDeviceDuplicateCount();
	int32_t* d_dupRelPos     = bu->getDeviceDupRelPos();


	int32_t init_pos = blockIdx.x * updatesPerBlock;

	for (int32_t i=0; i<updatesPerBlock; i++){
		int32_t pos=init_pos+i;
		if(pos>=d_incCount[0])
			break;
		int32_t indInc = d_indIncomplete[pos];
		int32_t src = d_updatesSrc[indInc];
		int32_t dst = d_updatesDst[indInc];

		int32_t srcInitSize = d_utilized[src];
		int32_t found=0;

		// if(threadIdx.x==0 && src==536954)
		// 	printf("CUDA - %d %d\n ", src,dst);

		for (int32_t e=0; e<srcInitSize; e+=blockDim.x){
			if(d_adj[src][e]==dst)
				found=1;
		}
		if(!found && threadIdx.x==0){
			int32_t ret =  atomicAdd(d_utilized+src, 1);
			if(ret<d_max[src]){
				int32_t dupInBatch=0;
				for(int32_t k=srcInitSize; k<ret; k++){
					if (d_adj[src][k]==dst)
						dupInBatch=1;
				}
				if(!dupInBatch){
					d_adj[src][ret] = dst;
				}
				else{
					int32_t duplicateID =  atomicAdd(d_dupCount, 1);
					d_indDuplicate[duplicateID] = pos;
					d_dupRelPos[duplicateID] = ret;
				}
			}
			else{
				printf("This should never happen because of reallaction");
				// printf("%d %d %d\n",src,ret ,d_max[src]);
			}
		}
	}
}

// Currently using a single thread in the warp for duplicate edge removal
__global__ void deviceRemoveInsertedDuplicates(cuStinger* custing, BatchUpdate* bu,int32_t dupsPerBlock){

	int32_t* d_updatesSrc = bu->getDeviceSrc();
	int32_t* d_updatesDst = bu->getDeviceDst();
	int32_t* d_utilized = custing->getDeviceUtilized();
	int32_t** d_adj = custing->getDeviceAdj();
	int32_t* d_indDuplicate = bu->getDeviceIndDuplicate();
	int32_t* d_dupCount = bu->getDeviceDuplicateCount();
	int32_t* d_dupRelPos= bu->getDeviceDupRelPos();

	int32_t init_pos = blockIdx.x * dupsPerBlock;

	for (int32_t i=0; i<dupsPerBlock; i++){
		int32_t pos=init_pos+i;
		if(pos>=d_dupCount[0])	
			break;
		if (threadIdx.x==0){
			int32_t indDup = d_indDuplicate[pos];
			int32_t src    = d_updatesSrc[indDup];
			int32_t relPos = d_dupRelPos[indDup];

			int32_t ret =  atomicSub(d_utilized+src, 1);
			if(ret>0){
				d_adj[src][relPos] = d_adj[src][ret-1];
			}
		}
	}
}


void update(cuStinger &custing, BatchUpdate &bu)
{	
	dim3 numBlocks(1, 1);
	int32_t threads=32;
	dim3 threadsPerBlock(threads, 1);
	int32_t updatesPerBlock,dupsPerBlock,updateSize, dupInBatch;

	updateSize = bu.getHostBatchSize();
	numBlocks.x = ceil((float)updateSize/(float)threads);
	if (numBlocks.x>16000){
		numBlocks.x=16000;
	}	
	updatesPerBlock = ceil(float(updateSize)/float(numBlocks.x-1));

	deviceUpdatesSweep1<<<numBlocks,threadsPerBlock>>>(custing.devicePtr(), bu.devicePtr(),updatesPerBlock);
	checkLastCudaError("Error in the first update sweep");

	bu.copyDeviceToHostDupCount();
	dupInBatch = bu.getHostDuplicateCount();

	if(dupInBatch>0){
		numBlocks.x = ceil((float)dupInBatch/(float)threads);
		if (numBlocks.x>1000){
			numBlocks.x=1000;
		}	
		dupsPerBlock = ceil(float(dupInBatch)/float(numBlocks.x-1));
		deviceRemoveInsertedDuplicates<<<numBlocks,threadsPerBlock>>>(custing.devicePtr(), bu.devicePtr(),dupsPerBlock);
		checkLastCudaError("Error in the first duplication sweep");
	}

	bu.copyDeviceToHost();

	reAllocateMemoryAfterSweep1(custing,bu);
	
	//--------
	// Sweep 2
	//--------
	bu.copyDeviceToHostIncCount();
	updateSize = bu.getHostIncCount();
	bu.resetDeviceDuplicateCount();

	if(updateSize>0){
		numBlocks.x = ceil((float)updateSize/(float)threads);
		if (numBlocks.x>16000){
			numBlocks.x=16000;
		}	
		updatesPerBlock = ceil(float(updateSize)/float(numBlocks.x-1));

		deviceUpdatesSweep2<<<numBlocks,threadsPerBlock>>>(custing.devicePtr(), bu.devicePtr(),updatesPerBlock);
		checkLastCudaError("Error in the second update sweep");

		bu.copyDeviceToHostDupCount();
		dupInBatch = bu.getHostDuplicateCount();
		cout << "Dup 2nd sweep " << dupInBatch << endl;

		if(dupInBatch>0){
			numBlocks.x = ceil((float)dupInBatch/(float)threads);
			if (numBlocks.x>1000){
				numBlocks.x=1000;
			}	
			dupsPerBlock = ceil(float(dupInBatch)/float(numBlocks.x-1));
			deviceRemoveInsertedDuplicates<<<numBlocks,threadsPerBlock>>>(custing.devicePtr(), bu.devicePtr(),dupsPerBlock);
			checkLastCudaError("Error in the second duplication sweep");
		}
	}

	cout << "The number of duplicates in the second sweep : " << bu.getHostDuplicateCount();

	bu.resetHostIncCount();
	bu.resetHostDuplicateCount();		
	bu.resetDeviceIncCount();
	bu.resetDeviceDuplicateCount();
}


__global__ void deviceCopyMultipleAdjacencies(cuStinger* custing, BatchUpdate* bu, 
	int32_t** d_newadj, int32_t* requireUpdates, int32_t requireCount ,int32_t verticesPerThreadBlock)
{
	int32_t** d_cuadj = custing->d_adj;
	int32_t* d_utilized = custing->d_utilized;

	int32_t v_init=blockIdx.x*verticesPerThreadBlock;
	for (int v_hat=0; v_hat<verticesPerThreadBlock; v_hat++){
		int32_t v= requireUpdates[v_init+v_hat];
		if(v>=requireCount)
			break;
		for(int32_t e=threadIdx.x; e<d_utilized[v]; e+=blockDim.x){
			d_newadj[v][e] = d_cuadj[v][e];
			// d_cuadj[v][e] = d_cuadj[v][e];
		}
	}
}

void  copyMultipleAdjacencies(cuStinger& custing, BatchUpdate& bu,int32_t** d_newadj, 
	int32_t* requireUpdates, int32_t requireCount){

	dim3 numBlocks(1, 1);
	int32_t threads=32;
	dim3 threadsPerBlock(threads, 1);

	numBlocks.x = ceil((float)requireCount);
	if (numBlocks.x>16000){
		numBlocks.x=16000;
	}	
	int32_t verticesPerThreadBlock = ceil(float(requireCount)/float(numBlocks.x-1));

	cout << "### " << requireCount << " , " <<  numBlocks.x << " , " << verticesPerThreadBlock << " ###"  << endl; 

	deviceCopyMultipleAdjacencies<<<numBlocks,threadsPerBlock>>>(custing.devicePtr(), bu.devicePtr(),
		d_newadj, requireUpdates, requireCount, verticesPerThreadBlock);
	checkLastCudaError("Error in the first update sweep");


}

