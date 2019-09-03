/*
 * Copyright 2019 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "Firestore/core/src/firebase/firestore/local/leveldb_lru_reference_delegate.h"

#include <set>
#include <string>
#include <utility>

#include "Firestore/core/src/firebase/firestore/local/leveldb_persistence.h"
#include "Firestore/core/src/firebase/firestore/local/listen_sequence.h"
#include "Firestore/core/src/firebase/firestore/local/reference_set.h"
#include "Firestore/core/src/firebase/firestore/model/resource_path.h"
#include "Firestore/core/src/firebase/firestore/model/types.h"
#include "absl/strings/match.h"

namespace firebase {
namespace firestore {
namespace local {

using model::DocumentKey;
using model::ListenSequenceNumber;
using model::ResourcePath;

LevelDbLruReferenceDelegate::LevelDbLruReferenceDelegate(
    LevelDbPersistence* persistence, LruParams lru_params)
    : db_(persistence) {
  gc_ = absl::make_unique<LruGarbageCollector>(this, lru_params);
}

// Explicit default the destructor after all forward declared types have been
// fully declared.
LevelDbLruReferenceDelegate::~LevelDbLruReferenceDelegate() = default;

void LevelDbLruReferenceDelegate::Start() {
  ListenSequenceNumber highest_sequence_number =
      db_->query_cache()->highest_listen_sequence_number();
  listen_sequence_ = absl::make_unique<ListenSequence>(highest_sequence_number);
}

void LevelDbLruReferenceDelegate::AddInMemoryPins(ReferenceSet* set) {
  // We should be able to assert that additional_references_ is nullptr, but
  // due to restarts in spec tests it would fail.
  additional_references_ = set;
}

void LevelDbLruReferenceDelegate::AddReference(const DocumentKey& key) {
  WriteSentinel(key);
}

void LevelDbLruReferenceDelegate::RemoveReference(const DocumentKey& key) {
  WriteSentinel(key);
}

void LevelDbLruReferenceDelegate::RemoveMutationReference(
    const DocumentKey& key) {
  WriteSentinel(key);
}

void LevelDbLruReferenceDelegate::RemoveTarget(const QueryData& query_data) {
  QueryData updated =
      query_data.Copy(query_data.snapshot_version(), query_data.resume_token(),
                      current_sequence_number());
  db_->query_cache()->UpdateTarget(std::move(updated));
}

void LevelDbLruReferenceDelegate::UpdateLimboDocument(const DocumentKey& key) {
  WriteSentinel(key);
}

ListenSequenceNumber LevelDbLruReferenceDelegate::current_sequence_number() {
  HARD_ASSERT(current_sequence_number_ != kListenSequenceNumberInvalid,
              "Asking for a sequence number outside of a transaction");
  return current_sequence_number_;
}

void LevelDbLruReferenceDelegate::OnTransactionStarted(absl::string_view) {
  HARD_ASSERT(current_sequence_number_ == kListenSequenceNumberInvalid,
              "Previous sequence number is still in effect");
  current_sequence_number_ = listen_sequence_->Next();
}

void LevelDbLruReferenceDelegate::OnTransactionCommitted() {
  current_sequence_number_ = kListenSequenceNumberInvalid;
}

LruGarbageCollector* LevelDbLruReferenceDelegate::garbage_collector() {
  return gc_.get();
}

int64_t LevelDbLruReferenceDelegate::CalculateByteSize() {
  return db_->CalculateByteSize();
}

size_t LevelDbLruReferenceDelegate::GetSequenceNumberCount() {
  size_t total_count = db_->query_cache()->size();
  EnumerateOrphanedDocuments(
      [&total_count](const DocumentKey&, ListenSequenceNumber) {
        total_count++;
      });
  return total_count;
}

void LevelDbLruReferenceDelegate::EnumerateTargets(
    const TargetCallback& callback) {
  db_->query_cache()->EnumerateTargets(callback);
}

void LevelDbLruReferenceDelegate::EnumerateOrphanedDocuments(
    const OrphanedDocumentCallback& callback) {
  db_->query_cache()->EnumerateOrphanedDocuments(callback);
}

int LevelDbLruReferenceDelegate::RemoveOrphanedDocuments(
    ListenSequenceNumber upper_bound) {
  int count = 0;
  db_->query_cache()->EnumerateOrphanedDocuments(
      [&count, this, upper_bound](const DocumentKey& key,
                                  ListenSequenceNumber sequence_number) {
        if (sequence_number <= upper_bound) {
          if (!IsPinned(key)) {
            count++;
            db_->remote_document_cache()->Remove(key);
            RemoveSentinel(key);
          }
        }
      });
  return count;
}

int LevelDbLruReferenceDelegate::RemoveTargets(
    ListenSequenceNumber sequence_number, const LiveQueryMap& live_queries) {
  return db_->query_cache()->RemoveTargets(sequence_number, live_queries);
}

bool LevelDbLruReferenceDelegate::IsPinned(const DocumentKey& key) {
  if (additional_references_->ContainsKey(key)) {
    return true;
  }
  return MutationQueuesContainKey(key);
}

bool LevelDbLruReferenceDelegate::MutationQueuesContainKey(
    const DocumentKey& key) {
  const std::set<std::string>& users = db_->users();
  const ResourcePath& path = key.path();
  std::string buffer;
  auto it = db_->current_transaction()->NewIterator();
  // For each user, if there is any batch that contains this document in any
  // batch, we know it's pinned.
  for (const std::string& user : users) {
    std::string mutationKey = LevelDbDocumentMutationKey::KeyPrefix(user, path);
    it->Seek(mutationKey);
    if (it->Valid() && absl::StartsWith(it->key(), mutationKey)) {
      return true;
    }
  }
  return false;
}

void LevelDbLruReferenceDelegate::RemoveSentinel(const DocumentKey& key) {
  db_->current_transaction()->Delete(
      LevelDbDocumentTargetKey::SentinelKey(key));
}

void LevelDbLruReferenceDelegate::WriteSentinel(const DocumentKey& key) {
  std::string sentinelKey = LevelDbDocumentTargetKey::SentinelKey(key);
  std::string encodedSequenceNumber =
      LevelDbDocumentTargetKey::EncodeSentinelValue(current_sequence_number());
  db_->current_transaction()->Put(sentinelKey, encodedSequenceNumber);
}

}  // namespace local
}  // namespace firestore
}  // namespace firebase
