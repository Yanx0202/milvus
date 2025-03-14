// Copyright (C) 2019-2020 Zilliz. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance
// with the License. You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software distributed under the License
// is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
// or implied. See the License for the specific language governing permissions and limitations under the License

#include <boost_ext/dynamic_bitset_ext.hpp>
#include <cmath>

#include "knowhere/index/vector_index/VecIndex.h"
#include "knowhere/index/vector_index/ConfAdapter.h"
#include "knowhere/index/vector_index/ConfAdapterMgr.h"
#include "knowhere/index/vector_index/helpers/IndexParameter.h"
#include "knowhere/index/vector_index/adapter/VectorAdapter.h"
#include "query/SearchOnSealed.h"
#include "utils/Utils.h"

namespace milvus::query {

// negate bitset, and merge them into one
aligned_vector<uint8_t>
AssembleNegBitset(const BitsetSimple& bitset_simple) {
    int64_t N = 0;

    for (auto& bitset : bitset_simple) {
        N += bitset.size();
    }

    aligned_vector<uint8_t> result(upper_align(upper_div(N, 8), 64));

    if (bitset_simple.size() == 1) {
        auto& bitset = bitset_simple[0];
        auto byte_count = upper_div(bitset.size(), 8);
        auto src_ptr = boost_ext::get_data(bitset);
        memcpy(result.data(), src_ptr, byte_count);
    } else {
        auto acc_byte_count = 0;
        for (auto& bitset : bitset_simple) {
            auto size = bitset.size();
            AssertInfo(size % 8 == 0, "[AssembleNegBitset]Bitset size isn't times of 8");
            auto byte_count = size / 8;
            auto src_ptr = boost_ext::get_data(bitset);
            memcpy(result.data() + acc_byte_count, src_ptr, byte_count);
            acc_byte_count += byte_count;
        }
    }

    // revert the bitset
    for (int64_t i = 0; i < result.size(); ++i) {
        result[i] = ~result[i];
    }
    return result;
}

void
SearchOnSealed(const Schema& schema,
               const segcore::SealedIndexingRecord& record,
               const SearchInfo& search_info,
               const void* query_data,
               int64_t num_queries,
               const faiss::BitsetView& bitset,
               SearchResult& result,
               int64_t segment_id) {
    const std::string log_prefix = "[TODO: remove] debug #14077, segment_id = " + std::to_string(segment_id) + ", ";
    std::cout << log_prefix << "SearchOnSealed searching..., query_data_ptr = " << query_data
              << ", nq = " << num_queries << std::endl;
    auto topk = search_info.topk_;
    auto round_decimal = search_info.round_decimal_;

    auto field_offset = search_info.field_offset_;
    auto& field = schema[field_offset];
    // Assert(field.get_data_type() == DataType::VECTOR_FLOAT);
    auto dim = field.get_dim();

    std::cout << log_prefix << "SearchOnSealed init topk, round_decimal, field_offset, field and dim done" << std::endl;
    AssertInfo(record.is_ready(field_offset), "[SearchOnSealed]Record isn't ready");
    auto field_indexing = record.get_field_indexing(field_offset);
    std::cout << log_prefix << "SearchOnSealed get_field_indexing done" << std::endl;
    AssertInfo(field_indexing->metric_type_ == search_info.metric_type_,
               "Metric type of field index isn't the same with search info");

    auto final = [&] {
        auto ds = knowhere::GenDataset(num_queries, dim, query_data);
        std::cout << log_prefix << "SearchOnSealed GenDataset done" << std::endl;

        auto conf = search_info.search_params_;
        conf[milvus::knowhere::meta::TOPK] = search_info.topk_;
        conf[milvus::knowhere::Metric::TYPE] = MetricTypeToName(field_indexing->metric_type_);
        auto index_type = field_indexing->indexing_->index_type();
        std::cout << log_prefix << "SearchOnSealed get index_type done" << std::endl;
        auto adapter = milvus::knowhere::AdapterMgr::GetInstance().GetAdapter(index_type);
        std::cout << log_prefix << "SearchOnSealed GetAdapter done" << std::endl;
        AssertInfo(adapter->CheckSearch(conf, index_type, field_indexing->indexing_->index_mode()),
                   "[SearchOnSealed]Search params check failed");
        std::cout << log_prefix << "SearchOnSealed final done" << std::endl;
        return field_indexing->indexing_->Query(ds, conf, bitset);
    }();

    auto ids = final->Get<idx_t*>(knowhere::meta::IDS);
    auto distances = final->Get<float*>(knowhere::meta::DISTANCE);

    auto total_num = num_queries * topk;

    std::cout << log_prefix << "SearchOnSealed ids = " << ids << ", distance = " << distances
              << ", total_num = " << total_num << std::endl;
    const float multiplier = pow(10.0, round_decimal);
    if (round_decimal != -1) {
        const float multiplier = pow(10.0, round_decimal);
        for (int i = 0; i < total_num; i++) {
            distances[i] = round(distances[i] * multiplier) / multiplier;
        }
    }
    result.ids_.resize(total_num);
    result.distances_.resize(total_num);
    result.num_queries_ = num_queries;
    result.topk_ = topk;

    std::cout << log_prefix << "SearchOnSealed result assignment done" << std::endl;
    std::copy_n(ids, total_num, result.ids_.data());
    std::copy_n(distances, total_num, result.distances_.data());
    std::cout << log_prefix << "SearchOnSealed copy result done" << std::endl;
}
}  // namespace milvus::query
