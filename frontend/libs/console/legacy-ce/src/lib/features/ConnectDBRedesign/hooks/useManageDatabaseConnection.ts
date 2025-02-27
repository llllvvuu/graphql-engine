import { useCallback, useMemo } from 'react';
import { useQueryClient } from 'react-query';
import { exportMetadata } from '../../../metadata/actions';
import { useAppDispatch } from '../../../storeHooks';
import { generateQueryKeys } from '../../DatabaseRelationships/utils/queryClientUtils';
import { useMetadataMigration } from '../../MetadataAPI';
import { DatabaseConnection } from '../types';
import { usePushRoute } from './usePushRoute';
import {
  sendConnectDatabaseTelemetryEvent,
  transformErrorResponse,
} from '../utils';
import { useHttpClient } from '../../Network';
import { Driver } from '../../../dataSources';
import { useMetadata } from '../../hasura-metadata-api';

export const useManageDatabaseConnection = ({
  onSuccess,
  onError,
}: {
  onSuccess?: () => void;
  onError?: (err: Error) => void;
}) => {
  const queryClient = useQueryClient();
  const { mutateAsync, ...rest } = useMetadataMigration({
    errorTransform: transformErrorResponse,
  });
  const { data: resource_version } = useMetadata(m => m.resource_version);
  const push = usePushRoute();
  const dispatch = useAppDispatch();
  const httpClient = useHttpClient();

  const mutationOptions = useMemo(
    () => ({
      onSuccess: () => {
        queryClient.invalidateQueries(generateQueryKeys.metadata());
        onSuccess?.();

        // this code is only for the demo
        push('/data/manage');
        dispatch(exportMetadata());
      },
      onError: (err: Error) => {
        console.log('~', err);
        onError?.(err);
      },
    }),
    [dispatch, onError, onSuccess, push, queryClient]
  );

  const createConnection = useCallback(
    async (databaseConnection: DatabaseConnection) => {
      await mutateAsync(
        {
          query: {
            type: `${databaseConnection.driver}_add_source`,
            args: {
              name: databaseConnection.details.name,
              configuration: databaseConnection.details.configuration,
              customization: databaseConnection.details.customization,
            },
          },
        },
        mutationOptions
      );
      sendConnectDatabaseTelemetryEvent({
        httpClient,
        driver: databaseConnection.driver as Driver,
        dataSourceName: databaseConnection.details.name,
      });
    },
    [httpClient, mutateAsync, mutationOptions]
  );

  const editConnection = useCallback(
    async (
      databaseConnection: DatabaseConnection & { originalName: string }
    ) => {
      const renameConnectionPayload = {
        type: 'rename_source',
        args: {
          name: databaseConnection.originalName,
          new_name: databaseConnection.details.name,
        },
      };

      const updateConfigurationPayload = {
        type: `${databaseConnection.driver}_add_source`,
        args: {
          name: databaseConnection.details.name,
          configuration: databaseConnection.details.configuration,
          customization: databaseConnection.details.customization,
          replace_configuration: true,
        },
      };

      mutateAsync(
        {
          query: {
            type: 'bulk',
            source: databaseConnection.originalName,
            resource_version,
            args:
              databaseConnection.details.name ===
              databaseConnection.originalName
                ? [updateConfigurationPayload]
                : [renameConnectionPayload, updateConfigurationPayload],
          },
        },
        mutationOptions
      );
    },
    [mutateAsync, mutationOptions, resource_version]
  );

  return { createConnection, editConnection, ...rest };
};
