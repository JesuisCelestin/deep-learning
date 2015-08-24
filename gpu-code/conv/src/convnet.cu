///
/// \file convnet.cu
/// @brief


#include <time.h>

#include "convnet.hpp"
#include "layer_kernel.cuh"

using namespace std;

template <typename Dtype>
ConvNet<Dtype>::ConvNet(ConvParam* cp) : TrainLayer<Dtype>(cp){

	this->_cp = cp;
	this->_filt_pixs			= pow(this->_cp->getFilterSize(), 2);
	this->_conv_pixs			= pow(this->_cp->getOutSize(), 2);
	this->_padded_in_pixs		= pow(this->_cp->getPaddedInSize(), 2);
	this->_in_pixs		= pow(this->_cp->getInSize(), 2);
	cublasCreate(&this->handle);
	
	int pow2Length = _cp->getOutSize();
	if(pow2Length & (pow2Length - 1)){
		while(pow2Length & (pow2Length - 1)){
			pow2Length &= pow2Length - 1;
		}
		pow2Length *= 2;
	}
	_thread_num = pow2Length > MAX_THREAD_SIZE ? MAX_THREAD_SIZE : pow2Length;
	_num_box = pow(_cp->getBoxNumSize(), 2);
}

template <typename Dtype>
ConvNet<Dtype>::~ConvNet() {

	delete this->_w;
	delete this->_w_inc;
	delete this->_bias;
	delete this->_bias_inc;

	delete this->_y;
	delete this->_dE_dy;
	delete this->_dE_dw;
	delete this->_dE_db;

	delete unfold_x;
	delete dE_db_tmp;
	if(this->_cp->getPad() > 0)
		delete padded_x;
	if(_cp->getOutSize() > MAX_THREAD_SIZE && _overlap_len > 0)	
		delete unranged_dE_dx;
	if(_cp->getOutSize() > MAX_THREAD_SIZE){
		delete unranged_dE_dw;
		delete unfold_dE_db_tmp;
	}

	cublasDestroy(this->handle);
}

template <typename Dtype>
void ConvNet<Dtype>::initCuda() {

	this->_w            	= new Matrix<Dtype>(_filt_pixs \
									* this->_cp->getInChannel(), \
									this->_cp->getOutChannel());
	this->_bias         	= new Matrix<Dtype>(1, this->_cp->getOutChannel());
	this->_y            	= new Matrix<Dtype>(this->_cp->getMinibatchSize(), \
									this->_cp->getOutChannel() * _conv_pixs);
	this->_dE_dy        	= new Matrix<Dtype>(this->_y);

	this->_dE_dw          	= new Matrix<Dtype>(this->_w);
	this->_dE_db           	= new Matrix<Dtype>(this->_bias);

	this->_w_inc		 	= new Matrix<Dtype>(this->_w);
	this->_bias_inc		 	= new Matrix<Dtype>(this->_bias);

	if(this->_cp->getPad() > 0)
		this->padded_x 		= new Matrix<Dtype>(this->_cp->getMinibatchSize(), \
									this->_cp->getInChannel() * _padded_in_pixs);
	unfold_x 		= new Matrix<Dtype>(this->_cp->getMinibatchSize(), \
									this->_cp->getInChannel() * _padded_in_pixs);
	
	_overlap_len = _cp->getFilterSize() - _cp->getStride();
	if(_cp->getOutSize() > MAX_THREAD_SIZE && _overlap_len > 0){	
		unranged_dE_dx = new Matrix<Dtype>(_cp->getMinibatchSize(), \
				pow(_cp->getBoxInSize() * _cp->getBoxNumSize(), 2) \
				* _cp->getOutChannel());
	}
	unranged_dE_dw = new Matrix<Dtype>(_cp->getMinibatchSize(), \
			pow(_cp->getFilterSize(),2)*_cp->getInChannel() \
			*pow(_cp->getBoxNumSize(),2)*_cp->getOutChannel());
	if(_cp->getOutSize() > MAX_THREAD_SIZE){	
		unfold_dE_db_tmp		 = new Matrix<Dtype>(this->_cp->getMinibatchSize(), \
									this->_cp->getOutChannel()*pow(_cp->getBoxNumSize(), 2));
	}

	dE_db_tmp 				= new Matrix<Dtype>(this->_cp->getMinibatchSize(), \
									this->_cp->getOutChannel());

	this->_w_inc->zeros();
	this->_bias_inc->zeros();
}

template <typename Dtype>
void ConvNet<Dtype>::computeOutput(Matrix<Dtype>* x){

	this->_y->zeros();

	int num_kernel;
	int num_block;

//	x->reValue(1.0f);
//	this->_w->reValue(_filt_pixs, true);
//	this->_bias->reValue(2.0f);

	if(this->_cp->getPad() > 0){
		num_kernel = this->_cp->getMinibatchSize() * _in_pixs \
					 * this->_cp->getInChannel();
		num_block = MAX_NUM_KERNEL < (num_kernel / MAX_NUM_THREAD + 1) \
					? MAX_NUM_KERNEL : (num_kernel / MAX_NUM_THREAD + 1);
		padded_x->zeros();
		ori_to_padding<<<num_block, MAX_NUM_THREAD>>>(x->getDevData(), \
				padded_x->getDevData(), num_kernel, this->_cp->getInSize(), \
				this->_cp->getPaddedInSize(), this->_cp->getInChannel());
		cudaDeviceSynchronize();
		cudaCheckError();
	}else
		padded_x = x;

	//size表示一个正方形的边长，width，height表示矩阵的宽长
//if(_cp->getName() == "conv3")
//padded_x->showValue("_x");	

	dim3 blocks = dim3(_cp->getMinibatchSize(), _cp->getOutChannel()*_num_box);
	dim3 threads = dim3(_thread_num, _thread_num);

	int box_out_size = MAX_THREAD_SIZE > _cp->getOutSize() \
					? _cp->getOutSize() : MAX_THREAD_SIZE;
	forward_convolution<<<blocks, threads>>>(\
			padded_x->getDevData(), this->_w->getDevData(), this->_bias->getDevData(), \
			this->_y->getDevData(), \
				_cp->getPaddedInSize(), _cp->getInChannel(), _cp->getOutSize(), \
				_cp->getFilterSize(), _cp->getOutChannel(), _cp->getStride(), \
				box_out_size, _cp->getBoxNumSize());  
	cudaDeviceSynchronize();
	cudaCheckError();


//	this->_w->showValue("whk");
//	this->_y->showValue(this->_cp->getName() + "yh");
}

template <typename Dtype>
void ConvNet<Dtype>::computeDerivsOfPars(Matrix<Dtype>* x){

//	padded_x->reValue(1.0f);
//this->_dE_dy->reValue(_cp->getOutSize()*_cp->getOutSize(),true);

//	clock_t t;
//	t = clock();


	dim3 blocks = dim3(_cp->getMinibatchSize(), \
			_cp->getOutChannel()*_cp->getInChannel()*_num_box \
			*pow(_cp->getFilterSize(), 2));


	dim3 threads = dim3(_thread_num, _thread_num);

	int box_out_size = MAX_THREAD_SIZE > _cp->getOutSize() \
						? _cp->getOutSize() : MAX_THREAD_SIZE;

	int box_in_size = MAX_THREAD_SIZE > _cp->getOutSize() \
						  ? _cp->getPaddedInSize() : _cp->getBoxInSize();

	unranged_dE_dw->zeros();

	Dtype *dE_db_multi_channel;
	if(_cp->getOutSize() > MAX_THREAD_SIZE){
		unfold_dE_db_tmp->zeros();
		dE_db_multi_channel = unfold_dE_db_tmp->getDevData();
	}else{
		dE_db_tmp->zeros();
		dE_db_multi_channel = dE_db_tmp->getDevData();
	}

	cudaStream_t s1, s2;
	cudaStreamCreate(&s1);
	cudaStreamCreate(&s2);

	//每个线程只计算一个点，先将32*32输出块计算对应值存入共享变量，再用reduce
	compute_convolution_derivs<<<blocks, threads, \
		sizeof(Dtype)*box_out_size*box_out_size, s1>>>( \
			this->_dE_dy->getDevData(), padded_x->getDevData(), \
			unranged_dE_dw->getDevData(), \
			box_out_size, \
			_cp->getOutChannel(), _cp->getInChannel(), _cp->getPaddedInSize(), \
			_cp->getOutSize(), _cp->getFilterSize(), \
			_cp->getStride(), _cp->getBoxNumSize());	
	
	blocks = dim3(_cp->getMinibatchSize(), _cp->getOutChannel()*_num_box);
	//从100*out_size*out_size*out_size*out_channel先生成100*out_channel*_num_box
	compute_derivs_of_bias<<<blocks, threads, sizeof(Dtype)*box_out_size*box_out_size, \
		s2>>>( \
			this->_dE_dy->getDevData(), dE_db_multi_channel, \
					_cp->getOutSize(), _cp->getOutChannel(), \
					box_out_size, _cp->getBoxNumSize());

	cudaDeviceSynchronize();
	cudaCheckError();
	
//	t = clock() - t;
//	cout << _cp->getName() << " dervis w  convolution: "<< ((float)t/CLOCKS_PER_SEC) << "s.\n";
//	t = clock();

	blocks = dim3(1, _cp->getInChannel()*_cp->getOutChannel());
	compact_dervis_w<<<blocks, threads, 0, s1>>>( \
				unranged_dE_dw->getDevData(), this->_dE_dw->getDevData(), \
				_cp->getFilterSize(), _cp->getBoxNumSize(), _cp->getMinibatchSize(), \
				_cp->getInChannel(), _cp->getOutChannel());
	
	if(_cp->getOutSize() > MAX_THREAD_SIZE){
		blocks = dim3(_cp->getMinibatchSize(), _cp->getOutChannel());
		compute_derivs_of_bias<<<blocks, threads, sizeof(Dtype)*_num_box, s2>>>( \
				unfold_dE_db_tmp->getDevData(), dE_db_tmp->getDevData(), \
						_cp->getBoxNumSize(), _cp->getOutChannel(), _cp->getBoxNumSize(), 1);
	}
	cudaDeviceSynchronize();
	cudaCheckError();
	
	dE_db_tmp->sumRow(this->_dE_db);

//	t = clock() - t;
//	cout << _cp->getName() << " compact w  convolution: "<< ((float)t/CLOCKS_PER_SEC) << "s.\n";

//	if(_cp->getName() != "conv3"){
//		this->_dE_dw->showValue("dE_dw");
//	unfold_dE_db_tmp->showValue(this->_cp->getName() + "dEdb");
//	}

//unranged_dE_dw->showValue(_cp->getName()+"unranged_dE_dw");
//this->_dE_dw->showValue(_cp->getName() + "dE_dw");
//this->_dE_db->showValue(this->_cp->getName() + "dEdb");

	cudaStreamDestroy(s1);
	cudaStreamDestroy(s2);

}

template <typename Dtype>
void ConvNet<Dtype>::computeDerivsOfInput(Matrix<Dtype>* dE_dx){

	
//	clock_t t;
//	t = clock();
//this->_dE_dy->reValue(1.0f);
//this->_w->reValue(_filt_pixs, true);
//this->_w->showValue("w");


	dim3 blocks = dim3(_cp->getMinibatchSize(), _cp->getInChannel() * _num_box);
	dim3 threads = dim3(_thread_num, _thread_num);

	int box_out_size = MAX_THREAD_SIZE > _cp->getOutSize() \
						? _cp->getOutSize() : MAX_THREAD_SIZE;

	int box_in_size = MAX_THREAD_SIZE > _cp->getOutSize() \
						  ? _cp->getPaddedInSize() : _cp->getBoxInSize();

	Dtype* p_dE_dx;
	if(MAX_THREAD_SIZE < _cp->getOutSize() && _overlap_len > 0){
		unranged_dE_dx->zeros();
		p_dE_dx = unranged_dE_dx->getDevData();
	}else if(_cp->getPad() > 0){
		unfold_x->zeros();
		p_dE_dx = unfold_x->getDevData();
	}else{
		dE_dx->zeros();
		p_dE_dx = dE_dx->getDevData();
	}

	backward_convolution<<<blocks, threads, sizeof(Dtype)*pow(box_in_size,2)>>>( \
			this->_dE_dy->getDevData(), this->_w->getDevData(), \
			p_dE_dx, box_in_size, box_out_size, \
			_cp->getOutChannel(), _cp->getInChannel(), \
			_cp->getOutSize(), _cp->getFilterSize(), \
			_cp->getStride(), _cp->getBoxNumSize());	
	cudaDeviceSynchronize();
	cudaCheckError();
//unfold_x->showValue(this->_cp->getName() + "dx");

	if(_cp->getOutSize() > MAX_THREAD_SIZE && _overlap_len > 0){
		
		if(this->_cp->getPad() > 0){
			unfold_x->zeros();
			p_dE_dx = unfold_x->getDevData();
		}else{
			dE_dx->zeros();
			p_dE_dx = dE_dx->getDevData();
		}
		
		compactOverlap<<<_cp->getMinibatchSize(), _cp->getInChannel()>>>( \
				unranged_dE_dx->getDevData(), p_dE_dx, _cp->getPaddedInSize(), \
				_cp->getInChannel(),  _overlap_len, \
				_cp->getBoxInSize(), _cp->getBoxNumSize());
		cudaDeviceSynchronize();
		cudaCheckError();
//unranged_dE_dx->showValue("unrangeddEdx");
	}
	if(this->_cp->getPad() > 0){
		int num_kernel = this->_cp->getMinibatchSize() * _in_pixs \
					 * this->_cp->getInChannel();
		int num_block = MAX_NUM_KERNEL < (num_kernel / MAX_NUM_THREAD + 1) \
					? MAX_NUM_KERNEL : (num_kernel / MAX_NUM_THREAD + 1);
		pad_to_ori<<<num_block, MAX_NUM_THREAD>>>(dE_dx->getDevData(), \
				p_dE_dx, num_kernel, this->_cp->getInSize(), \
				this->_cp->getPaddedInSize(), this->_cp->getInChannel());
		cudaDeviceSynchronize();
		cudaCheckError();

//unfold_x->showValue(this->_cp->getName() + "unfolddx");
//dE_dx->showValue(this->_cp->getName() + "dx");
			
	}

//	t = clock() - t;
//	cout << _cp->getName() << " backward convolution: "<< ((float)t/CLOCKS_PER_SEC) << "s.\n";
}
