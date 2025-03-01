{-# LANGUAGE QuasiQuotes #-}

-- |
-- Tests that we can decode Arrays values correctly
module Test.Databases.Postgres.ArraySpec (spec) where

import Data.Aeson (Value)
import Data.List.NonEmpty qualified as NE
import Harness.Backend.Citus qualified as Citus
import Harness.Backend.Cockroach qualified as Cockroach
import Harness.Backend.Postgres qualified as Postgres
import Harness.GraphqlEngine (postGraphql, postGraphqlWithVariables)
import Harness.Quoter.Graphql (graphql)
import Harness.Quoter.Yaml (interpolateYaml, yaml)
import Harness.Schema qualified as Schema
import Harness.Test.Fixture qualified as Fixture
import Harness.TestEnvironment (GlobalTestEnvironment, TestEnvironment)
import Harness.Yaml (shouldReturnYaml)
import Hasura.Prelude
import Test.Hspec (SpecWith, describe, it)

spec :: SpecWith GlobalTestEnvironment
spec = do
  Fixture.run
    ( NE.fromList
        [ (Fixture.fixture $ Fixture.Backend Postgres.backendTypeMetadata)
            { Fixture.setupTeardown = \(testEnv, _) ->
                [ Postgres.setupTablesAction schema testEnv
                ]
            },
          (Fixture.fixture $ Fixture.Backend Citus.backendTypeMetadata)
            { Fixture.setupTeardown = \(testEnv, _) ->
                [ Citus.setupTablesAction schema testEnv
                ]
            },
          (Fixture.fixture $ Fixture.Backend Cockroach.backendTypeMetadata)
            { Fixture.setupTeardown = \(testEnv, _) ->
                [ Cockroach.setupTablesAction schema testEnv
                ]
            }
        ]
    )
    singleArrayTests

  -- CockroachDB does not support nested arrays
  -- https://www.cockroachlabs.com/docs/stable/array.html
  Fixture.run
    ( NE.fromList
        [ (Fixture.fixture $ Fixture.Backend Postgres.backendTypeMetadata)
            { Fixture.setupTeardown = \(testEnv, _) ->
                [ Postgres.setupTablesAction schema testEnv
                ]
            },
          (Fixture.fixture $ Fixture.Backend Citus.backendTypeMetadata)
            { Fixture.setupTeardown = \(testEnv, _) ->
                [ Citus.setupTablesAction schema testEnv
                ]
            }
        ]
    )
    nestedArrayTests

  -- CockroachDB does not support json arrays
  Fixture.run
    ( NE.fromList
        [ (Fixture.fixture $ Fixture.Backend Postgres.backendTypeMetadata)
            { Fixture.setupTeardown = \(testEnv, _) ->
                [ Postgres.setupTablesAction schema testEnv
                ]
            },
          (Fixture.fixture $ Fixture.Backend Citus.backendTypeMetadata)
            { Fixture.setupTeardown = \(testEnv, _) ->
                [ Citus.setupTablesAction schema testEnv
                ]
            }
        ]
    )
    jsonArrayTests

--------------------------------------------------------------------------------
-- Schema

textArrayType :: Schema.ScalarType
textArrayType =
  Schema.TCustomType
    $ Schema.defaultBackendScalarType
      { Schema.bstPostgres = Just "text[]",
        Schema.bstCitus = Just "text[]",
        Schema.bstCockroach = Just "text[]"
      }

nestedIntArrayType :: Schema.ScalarType
nestedIntArrayType =
  Schema.TCustomType
    $ Schema.defaultBackendScalarType
      { Schema.bstPostgres = Just "int[][]",
        Schema.bstCitus = Just "int[][]",
        Schema.bstCockroach = Just "int[]" -- nested arrays aren't supported in Cockroach, so we'll skip this test anyway
      }

jsonArrayType :: Schema.ScalarType
jsonArrayType =
  Schema.TCustomType
    $ Schema.defaultBackendScalarType
      { Schema.bstPostgres = Just "json[]",
        Schema.bstCitus = Just "json[]",
        Schema.bstCockroach = Just "json" -- arrays of json aren't supported in Cockroach, so we'll skip this test
      }

schema :: [Schema.Table]
schema =
  [ (Schema.table "author")
      { Schema.tableColumns =
          [ Schema.column "id" Schema.defaultSerialType,
            Schema.column "name" Schema.TStr,
            Schema.column "emails" textArrayType,
            Schema.column "grid" nestedIntArrayType,
            Schema.column "jsons" jsonArrayType
          ],
        Schema.tablePrimaryKey = ["id"]
      }
  ]

--------------------------------------------------------------------------------
-- Tests

singleArrayTests :: SpecWith TestEnvironment
singleArrayTests = do
  describe "Saves arrays" $ do
    it "Using native postgres array syntax" \testEnvironment -> do
      let expected :: Value
          expected =
            [interpolateYaml|
              data:
                insert_hasura_author:
                  affected_rows: 1
                  returning:
                    - name: "Ash"
                      emails: ["ash@ash.com", "ash123@ash.com"]
            |]

          actual :: IO Value
          actual =
            postGraphql
              testEnvironment
              [graphql|
                mutation {
                  insert_hasura_author (
                    objects: [
                      {
                        name: "Ash",
                        emails: "{ash@ash.com, ash123@ash.com}",
                        grid: "{}",
                        jsons: "{}"
                      }
                    ]
                  ) {
                    affected_rows
                    returning {
                      name
                      emails
                    }
                  }
                }
              |]

      shouldReturnYaml testEnvironment actual expected

    it "Text array using native GraphQL array syntax" \testEnvironment -> do
      let expected :: Value
          expected =
            [interpolateYaml|
              data:
                insert_hasura_author:
                  affected_rows: 1
                  returning:
                    - name: "Ash"
                      emails: ["ash@ash.com", "ash123@ash.com"]
            |]

          actual :: IO Value
          actual =
            postGraphql
              testEnvironment
              [graphql|
                mutation {
                  insert_hasura_author (
                    objects: [
                      {
                        name: "Ash",
                        emails: ["ash@ash.com", "ash123@ash.com"],
                        grid: [],
                        jsons: []
                      }
                    ]
                  ) {
                    affected_rows
                    returning {
                      name
                      emails
                    }
                  }
                }
              |]

      shouldReturnYaml testEnvironment actual expected

jsonArrayTests :: SpecWith TestEnvironment
jsonArrayTests = do
  describe "saves JSON arrays" $ do
    it "JSON array using native GraphQL array syntax" \testEnvironment -> do
      let expected :: Value
          expected =
            [interpolateYaml|
              data:
                insert_hasura_author:
                  affected_rows: 1
                  returning:
                    - name: "Bruce"
                      jsons: [{ name: "Mr Horse", age: 100}, { name: "Mr Dog", age: 1}]
            |]

          actual :: IO Value
          actual =
            postGraphql
              testEnvironment
              [graphql|
                mutation {
                  insert_hasura_author (
                    objects: [
                      {
                        name: "Bruce",
                        emails: ["something@something.com"]
                        grid: [],
                        jsons: ["{ \"name\": \"Mr Horse\", \"age\": 100}", "{\"name\":\"Mr Dog\", \"age\": 1}"]
                      }
                    ]
                  ) {
                    affected_rows
                    returning {
                      name
                      jsons
                    }
                  }
                }
              |]

      shouldReturnYaml testEnvironment actual expected

    it "JSON array using native GraphQL array syntax and variable" \testEnvironment -> do
      let expected :: Value
          expected =
            [interpolateYaml|
              data:
                insert_hasura_author:
                  affected_rows: 1
                  returning:
                    - name: "Bruce"
                      jsons: [{ name: "Mr Horse", age: 100}, "horses"]
            |]

          actual :: IO Value
          actual =
            postGraphqlWithVariables
              testEnvironment
              [graphql|
                mutation json_variables_test($jsonArray: [json]) {
                  insert_hasura_author (
                    objects: [
                      {
                        name: "Bruce",
                        emails: ["something2@something2.com"],
                        grid: [],
                        jsons: $jsonArray
                      }
                    ]
                  ) {
                    affected_rows
                    returning {
                      name
                      jsons
                    }
                  }
                }
              |]
              [yaml|
                jsonArray: [{ name: "Mr Horse", age: 100 }, "horses"]
              |]

      shouldReturnYaml testEnvironment actual expected

  describe "Filters with contains" $ do
    it "finds values using _contains" \testEnvironment -> do
      void
        $ postGraphql
          testEnvironment
          [graphql|
                mutation {
                  insert_hasura_author (
                    objects: [
                      {
                        name: "contains",
                        emails: ["horse@horse.com", "dog@dog.com"],
                        grid: [],
                        jsons: []
                      }
                    ]
                  ) {
                    affected_rows
                    returning {
                      name
                      emails
                    }
                  }
                }
              |]

      let expected :: Value
          expected =
            [interpolateYaml|
              data:
                hasura_author:
                  - name: contains
            |]

          actual :: IO Value
          actual =
            postGraphql
              testEnvironment
              [graphql|
                query {
                  hasura_author (where: { emails: {_contains:["horse@horse.com"]}}) {
                    name
                  }
                }
              |]

      shouldReturnYaml testEnvironment actual expected

    it "finds values using _contained_in" \testEnvironment -> do
      void
        $ postGraphql
          testEnvironment
          [graphql|
                mutation {
                  insert_hasura_author (
                    objects: [
                      {
                        name: "contained_in",
                        emails: ["horse@horse2.com", "dog@dog2.com"],
                        grid: [],
                        jsons: []
                      }
                    ]
                  ) {
                    affected_rows
                    returning {
                      name
                      emails
                    }
                  }
                }
              |]

      let expected :: Value
          expected =
            [interpolateYaml|
              data:
                hasura_author:
                  - name: contained_in
            |]

          actual :: IO Value
          actual =
            postGraphql
              testEnvironment
              [graphql|
                query {
                  hasura_author (where: { emails: {_contained_in:["cat@cat2.com","dog@dog2.com", "horse@horse2.com"]}}) {
                    name
                  }
                }
              |]

      shouldReturnYaml testEnvironment actual expected

nestedArrayTests :: SpecWith TestEnvironment
nestedArrayTests = do
  describe "Saves nested arrays" $ do
    -- Postgres introspection is able to tell us about thing[] but thing[][] always comes
    -- back as unknown, so the only way to operate on these values continues to
    -- be with Postgres native array syntax. This test is to ensure we have not
    -- broken that.
    it "Using native postgres array syntax" \testEnvironment -> do
      let expected :: Value
          expected =
            [interpolateYaml|
                data:
                  insert_hasura_author:
                    affected_rows: 1
                    returning:
                      - name: "Ash"
                        grid: [[1,2,3],
                              [4,5,6]]
              |]

          actual :: IO Value
          actual =
            postGraphql
              testEnvironment
              [graphql|
                  mutation {
                    insert_hasura_author (
                      objects: [
                        {
                          name: "Ash",
                          emails: "{}",
                          grid: "{{1,2,3},{4,5,6}}",
                          jsons: "{}"
                        }
                      ]
                    ) {
                      affected_rows
                      returning {
                        name
                        grid
                      }
                    }
                  }
                |]

      shouldReturnYaml testEnvironment actual expected
