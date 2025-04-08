use std::ops::Range;
use std::path::Path;

use async_trait::async_trait;
use fedimint_core::db::{
    IDatabaseTransactionOps, IDatabaseTransactionOpsCore, IRawDatabase, IRawDatabaseTransaction,
    PrefixStream,
};
use futures_util::{stream, StreamExt};
use redb::{Database, ReadableTable, TableDefinition, WriteTransaction};

#[derive(Debug)]
pub struct Redb(Database);

pub struct RedbTransaction {
    write_tx: WriteTransaction,
}

impl std::fmt::Debug for RedbTransaction {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RedbTransaction").finish()
    }
}

const TABLE: TableDefinition<&[u8], &[u8]> = TableDefinition::new("fedimint");

impl Redb {
    pub fn open(name: &str) -> anyhow::Result<Redb> {
        Ok(Redb(Database::create(name)?))
    }
}

#[async_trait]
impl IRawDatabase for Redb {
    type Transaction<'a> = RedbTransaction;
    async fn begin_transaction<'a>(&'a self) -> RedbTransaction {
        let write_tx = self
            .0
            .begin_write()
            .expect("Failed to start redb write transaction");
        RedbTransaction { write_tx }
    }

    fn checkpoint(&self, _backup_path: &Path) -> anyhow::Result<()> {
        // Redb does not support checkpointing
        Ok(())
    }
}

#[async_trait]
impl IDatabaseTransactionOpsCore for RedbTransaction {
    async fn raw_insert_bytes(
        &mut self,
        key: &[u8],
        value: &[u8],
    ) -> anyhow::Result<Option<Vec<u8>>> {
        let mut table = self.write_tx.open_table(TABLE)?;
        let prev_val = { table.get(key)?.map(|b| b.value().to_vec()) };
        table.insert(key, value)?;
        Ok(prev_val)
    }

    /// Get key value
    async fn raw_get_bytes(&mut self, key: &[u8]) -> anyhow::Result<Option<Vec<u8>>> {
        let table = self.write_tx.open_table(TABLE)?;
        let val = table.get(key)?.map(|b| b.value().to_vec());
        Ok(val)
    }

    /// Remove entry by `key`
    async fn raw_remove_entry(&mut self, key: &[u8]) -> anyhow::Result<Option<Vec<u8>>> {
        let mut table = self.write_tx.open_table(TABLE)?;
        let prev_val = { table.get(key)?.map(|b| b.value().to_vec()) };
        table.remove(key)?;
        Ok(prev_val)
    }

    /// Returns an stream of key-value pairs with keys that start with
    /// `key_prefix`, sorted by key.
    async fn raw_find_by_prefix(&mut self, key_prefix: &[u8]) -> anyhow::Result<PrefixStream<'_>> {
        let table = self.write_tx.open_table(TABLE)?;
        let range = table
            .range(key_prefix..)?
            .filter_map(Result::ok)
            .take_while(|(key, _)| key.value().starts_with(key_prefix))
            .map(|(key, value)| (key.value().to_vec(), value.value().to_vec()))
            .collect::<Vec<_>>();

        Ok(Box::pin(stream::iter(range)))
    }

    /// Same as [`Self::raw_find_by_prefix`] but the order is descending by key.
    async fn raw_find_by_prefix_sorted_descending(
        &mut self,
        key_prefix: &[u8],
    ) -> anyhow::Result<PrefixStream<'_>> {
        let table = self.write_tx.open_table(TABLE)?;
        let mut range = table
            .range(key_prefix..)?
            .filter_map(Result::ok)
            .take_while(|(key, _)| key.value().starts_with(key_prefix))
            .map(|(key, value)| (key.value().to_vec(), value.value().to_vec()))
            .collect::<Vec<_>>();
        range.sort_by(|a, b| a.cmp(b).reverse());

        Ok(Box::pin(stream::iter(range)))
    }

    /// Returns an stream of key-value pairs with keys within a `range`, sorted
    /// by key. [`Range`] is an (half-open) range bounded inclusively below and
    /// exclusively above.
    async fn raw_find_by_range(&mut self, range: Range<&[u8]>) -> anyhow::Result<PrefixStream<'_>> {
        let table = self.write_tx.open_table(TABLE)?;
        let range = table
            .range(range)?
            .filter_map(Result::ok)
            .map(|(key, value)| (key.value().to_vec(), value.value().to_vec()))
            .collect::<Vec<_>>();

        Ok(Box::pin(stream::iter(range)))
    }

    /// Delete keys matching prefix
    async fn raw_remove_by_prefix(&mut self, key_prefix: &[u8]) -> anyhow::Result<()> {
        let keys = self
            .raw_find_by_prefix(key_prefix)
            .await?
            .map(|kv| kv.0)
            .collect::<Vec<_>>()
            .await;
        for key in keys {
            self.raw_remove_entry(key.as_slice()).await?;
        }
        Ok(())
    }
}

#[async_trait]
impl IDatabaseTransactionOps for RedbTransaction {
    async fn rollback_tx_to_savepoint(&mut self) -> anyhow::Result<()> {
        let save = self.write_tx.list_persistent_savepoints()?.last();
        if let Some(id) = save {
            let savepoint = self.write_tx.get_persistent_savepoint(id)?;
            self.write_tx.restore_savepoint(&savepoint)?;
            self.write_tx.delete_persistent_savepoint(id)?;
        }
        Ok(())
    }

    async fn set_tx_savepoint(&mut self) -> anyhow::Result<()> {
        self.write_tx.persistent_savepoint()?;
        Ok(())
    }
}

#[async_trait]
impl IRawDatabaseTransaction for RedbTransaction {
    async fn commit_tx(self) -> anyhow::Result<()> {
        self.write_tx.commit()?;
        Ok(())
    }
}
