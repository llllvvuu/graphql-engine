import { Table } from '@/features/hasura-metadata-types';
import { defaultDatabaseProps } from '../common/defaultDatabaseProps';
import { Database, Feature } from '../index';
import {
  getTablesListAsTree,
  getTrackableTables,
  getTableColumns,
  getDatabaseConfiguration,
  getSupportedOperators,
  getFKRelationships,
} from './introspection';
import { getTableRows } from './query';

/**
 * Why is GDCTable as string[] ?
 * It denotes the table along with it's hierarchy based on the DB. For example, in a mysql source
 * you'd have just the table name -> ["Album"] but in a db with schemas -> ["Public", "Album"].
 */
export type GDCTable = string[];

export const gdc: Database = {
  ...defaultDatabaseProps,
  introspection: {
    getDriverInfo: async () => Feature.NotImplemented,
    getDatabaseConfiguration,
    getTrackableTables,
    getDatabaseHierarchy: async () => {
      /**
       * Once we have the API for fetching the hierarchy info via HGE, we can add that logic here
       */
      return Feature.NotImplemented;
    },
    getTableColumns,
    getFKRelationships,
    getTablesListAsTree,
    getSupportedOperators,
  },
  query: {
    getTableRows,
  },
  config: {
    getDefaultQueryRoot: async (table: Table) => {
      return (table as GDCTable).join('_');
    },
  },
};